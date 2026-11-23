import Foundation
import LocalWaveDomain
import LocalWaveCore
import os

public actor DefaultSourceSyncService: SourceSyncService {
    let logger = createLogger(subsystem: subsystem, category: "SourceSyncService")

    let sourceRepository: SourceRepository
    private let sourceAccess: SourceAccess
    private let excludedURLs: [URL]
    let sourcePathRepository: SourcePathRepository
    let sourcePathSearchRepository: SourcePathSearchRepository

    public init(
        sourceRepository: SourceRepository,
        sourcePathSearchRepository: SourcePathSearchRepository,
        sourcePathRepository: SourcePathRepository,
        sourceAccess: SourceAccess? = nil,
        excludedURLs: [URL] = LocalWaveGeneratedPaths.urls
    ) {
        self.sourceRepository = sourceRepository
        self.sourceAccess = sourceAccess ?? SourceAccess(repository: sourceRepository)
        self.excludedURLs = excludedURLs
        self.sourcePathRepository = sourcePathRepository
        self.sourcePathSearchRepository = sourcePathSearchRepository
    }

    public func syncDir(
        sourceId: Int64, folderURL: URL, onCurrentURL: ((_ url: URL?) -> Void)?,
        onSetLoading: ((_ loading: Bool) -> Void)?
    ) async throws
        -> Source?
    {
        logger.debug("starting to collect items")
        do {
            onSetLoading?(true)
            defer { onSetLoading?(false) }
            let root = try await sourceAccess.rootURL(sourceId: sourceId)
            let liveSource = try await sourceRepository.getOne(id: sourceId)
            let registeredRoot = liveSource.map { makeURLFromString($0.dirPath) } ?? folderURL
            let result = try await syncDirInner(
                folderURL: folderURL, onCurrentURL: onCurrentURL, onSetLoading: onSetLoading, resolvedRootURL: root
            )
            // runId is used as the exact keep-set when stale paths are pruned.
            // Millisecond timestamps can repeat on fast consecutive scans,
            // leaving entries from the earlier scan behind.
            let runId = Int64.random(in: Int64.min...Int64.max)

            let itemsToCreate = result?.allItems.map { x in
                // Bookmark resolution can change /var to /private/var; keep IDs relative to the registered root.
                let registeredURL = registeredRoot.appendingPathComponent(x.relativePath, isDirectory: x.isDirectory)
                let parentPathId = makeURLHash(registeredURL.deletingLastPathComponent())
                let pathId = makeURLHash(registeredURL)
                return SourcePath(
                    id: nil,
                    sourceId: sourceId,
                    pathId: pathId,
                    parentPathId: parentPathId,
                    name: x.name,
                    relativePath: x.relativePath,
                    isDirectory: x.isDirectory,
                    fileHashSHA256: nil,
                    runId: runId,
                    createdAt: Date(),
                    updatedAt: nil,
                    fileSize: x.fileSize
                )
            }

            let items = itemsToCreate ?? []
            let numberOfItemsToUpsert = items.count

            logger.debug("upserting \(numberOfItemsToUpsert) items")
            try await sourcePathRepository.batchUpsert(paths: items)
            try await sourcePathSearchRepository.batchUpsertIntoFTS(paths: items)

            logger.debug("removing stale paths...")
            let deletedCount = try await sourcePathRepository.deleteMany(
                sourceId: sourceId, excludingRunId: runId
            )
            try await sourcePathSearchRepository.batchDeleteFTS(
                sourceId: sourceId, excludingRunId: runId
            )
            logger.debug("removed \(deletedCount) stale paths")

            if let result = result {
                let totalAudioFiles = result.totalAudioFiles
                logger.debug("updating source \(sourceId)")
                if var lib = try await sourceRepository.getOne(id: sourceId) {
                    lib.lastSyncedAt = Date()
                    lib.updatedAt = Date()
                    lib.totalPaths = totalAudioFiles
                    lib.syncError = nil
                    return try await sourceRepository.updateSource(source: lib)
                } else {
                    logger.error("for some reason source \(sourceId) wasn't found")
                }
            }

            if var lib = try await sourceRepository.getOne(id: sourceId) {
                lib.lastSyncedAt = Date()
                lib.updatedAt = Date()
                lib.totalPaths = result?.totalAudioFiles ?? 0 // Ensure totalPaths is set
                lib.syncError = nil
                return try await sourceRepository.updateSource(source: lib)
            }
            return nil
        } catch {
            logger.error("sync dir error: \(error)")
            if var lib = try await sourceRepository.getOne(id: sourceId) {
                lib.lastSyncedAt = Date()
                lib.updatedAt = Date()
                lib.syncError = "\(error)"
                _ = try await sourceRepository.updateSource(source: lib)
            }
            // Do not let callers continue with a stale source-path index. In
            // particular, SyncViewState must not import the old paths and
            // present that as a successful rescan.
            throw error
        }
    }

    public func syncDirInner(
        folderURL: URL,
        onCurrentURL: ((_ url: URL) -> Void)?,
        onSetLoading _: ((_ loading: Bool) -> Void)?,
        resolvedRootURL: URL? = nil
    ) async throws
        -> SourceSyncResult?
    {
        var audioURLs: [SourceSyncResultItem] = []
        var result = [String: SourceSyncResultItem]()
        let mediaExtensions = MediaFileSupport.extensions
        do {
            let scanRoot: URL
            var scoped = false
            if let resolvedRootURL {
                scanRoot = resolvedRootURL
                scoped = scanRoot.startAccessingSecurityScopedResource()
                guard scoped || FileManager.default.isReadableFile(atPath: scanRoot.path) else {
                    throw CustomError.genericError("Folder access has expired. Reconnect its source folder.")
                }
            }
            else {
                let key = makeBookmarkKey(folderURL)
                guard let bookmark = LocalWavePreferences.current.data(forKey: key) else {
                    throw CustomError.genericError("No bookmark found. Choose the source folder again.")
                }
                var stale = false
                scanRoot = try URL(resolvingBookmarkData: bookmark, options: sourceBookmarkResolutionOptions, bookmarkDataIsStale: &stale)
                scoped = scanRoot.startAccessingSecurityScopedResource()
                guard scoped || FileManager.default.isReadableFile(atPath: scanRoot.path) else {
                    throw CustomError.genericError("Folder access has expired. Reconnect its source folder.")
                }
            }
            defer { if scoped { scanRoot.stopAccessingSecurityScopedResource() } }
            let folderURL = scanRoot
            let selectedFilesOnly = LocalWaveSelectedFilesSource.includesOnlySelectedFiles(at: folderURL)
            let selectedRelativePaths = LocalWaveSelectedFilesSource.selectedRelativePaths(at: folderURL)
            guard !LocalWaveGeneratedPaths.contains(folderURL, excludedURLs: excludedURLs) else {
                throw CustomError.genericError("Choose your original music folder. Power Music Station’s generated cache cannot be used as a source.")
            }

            // Coordinate the directory read so File Provider / app-group-backed
            // folders return their current contents rather than a stale
            // uncoordinated enumeration.
            var coordinationError: NSError?
            var enumerationError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(
                readingItemAt: folderURL, options: .withoutChanges, error: &coordinationError
            ) { readableRoot in
                guard let enumerator = FileManager.default.enumerator(
                    at: readableRoot, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants],
                    errorHandler: { _, error in enumerationError = error; return false }
                ) else {
                    enumerationError = CustomError.genericError("Unable to enumerate the source folder.")
                    return
                }
                for case let file as URL in enumerator {
                    if LocalWaveGeneratedPaths.contains(file, excludedURLs: excludedURLs) {
                        enumerator.skipDescendants()
                        continue
                    }
                    do {
                        onCurrentURL?(file)
                        let resourceValues = try file.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        guard let relativePath = FileHelper(fileURL: file).relativePath(from: readableRoot) else {
                            throw CustomError.genericError("Unable to resolve a path inside the source folder.")
                        }
                        if resourceValues.isDirectory == false {
                            guard !selectedFilesOnly || selectedRelativePaths.contains(relativePath) else { continue }
                            let sourceURL = folderURL.appendingPathComponent(relativePath)
                            let resultItem = SourceSyncResultItem(
                                rootURL: folderURL, current: sourceURL, isDirectory: false, fileSize: resourceValues.fileSize.map(Int64.init)
                            )
                            if mediaExtensions.contains(file.pathExtension.lowercased()) { audioURLs.append(resultItem) }
                            result[FileHelper(fileURL: sourceURL).toString()] = resultItem
                        } else if resourceValues.isDirectory == true {
                            if selectedFilesOnly && !selectedRelativePaths.contains(where: { $0.hasPrefix(relativePath + "/") }) {
                                enumerator.skipDescendants()
                                continue
                            }
                            let sourceURL = folderURL.appendingPathComponent(relativePath, isDirectory: true)
                            let resultItem = SourceSyncResultItem(
                                rootURL: folderURL, current: sourceURL, isDirectory: true
                            )
                            result[FileHelper(fileURL: sourceURL).toString()] = resultItem
                        }
                    } catch {
                        logger.error("Error reading resource values: \(error)")
                        enumerationError = error
                        break
                    }
                }
            }
            if let coordinationError { throw coordinationError }
            if let enumerationError { throw enumerationError }
            logger.debug("Total audio files found: \(audioURLs.count)")
            return SourceSyncResult(allItems: Array(result.values), audioFiles: audioURLs, totalAudioFiles: audioURLs.count)
        } catch {
            throw CustomError.genericError("error resolving bookmark: \(error)")
        }
    }
}
