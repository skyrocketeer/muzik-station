import LocalWaveData
import LocalWaveCore
import LocalWaveDomain
import Foundation
import os
import SwiftUI

enum LWImportCategory: String, CaseIterable, Identifiable, Sendable {
    case music, podcasts, audiobooks
    var id: String { rawValue }
    var title: String {
        switch self { case .music: "Music"; case .podcasts: "Podcasts"; case .audiobooks: "Audiobooks" }
    }
    var detail: String {
        switch self {
        case .music: "Songs and albums"
        case .podcasts: "Podcast episodes and shows"
        case .audiobooks: "Audiobook chapters and recordings"
        }
    }
}

enum LWImportCategoryStore {
    private static let key = "lwSourceImportCategories"
    static func set(_ category: LWImportCategory, for path: String) {
        var values = LocalWavePreferences.current.dictionary(forKey: key) as? [String: String] ?? [:]
        values[URL(fileURLWithPath: path).standardizedFileURL.path] = category.rawValue
        LocalWavePreferences.current.set(values, forKey: key)
    }
    static func category(for source: Source) -> LWImportCategory {
        let path = URL(fileURLWithPath: source.dirPath).standardizedFileURL.path
        let values = LocalWavePreferences.current.dictionary(forKey: key) as? [String: String] ?? [:]
        if let raw = values[path], let category = LWImportCategory(rawValue: raw) { return category }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name == "podcasts" { return .podcasts }
        if name == "audiobooks" { return .audiobooks }
        return .music
    }
}

// MARK: - Complete SQLitePlaylistSongRepository implementation

@MainActor
class DependencyContainer: ObservableObject {
    let userService: UserService
    let userCloudService: UserCloudService
    let icloudProvider: ICloudProvider
    let sourceService: SourceService
    let sourceAccess: SourceAccess
    let songRepository: SongRepository
    let sourcePathRepository: SourcePathRepository
    let sourcePathSearchRepository: SourcePathSearchRepository
    let songImportService: SongImportService
    let playerPersistenceService: PlayerPersistenceService
    let playlistRepo: PlaylistRepository
    let playlistSongRepo: PlaylistSongRepository

    private var backgroundFileService: BackgroundFileService?

    @Published var sourceBrowseViewModels: [Int64: SourceBrowseViewModel] = [:]
    lazy var waveSyncViewModel = makeSyncViewModel()

    let logger = Logger(subsystem: subsystem, category: "DependencyContainer")

    func handleAppLaunch() {
        #if DEBUG && os(iOS)
        if LWReferenceFixture.enabled { return }
        #endif
        logger.debug("Handling app launch...")
        startBackgroundServices()
        verifyPendingCopies()
        logger.debug("App launch handling complete")
    }

    func trimOfflineCache() async throws {
        try await backgroundFileService?.enforceCacheLimit()
    }

    private func verifyPendingCopies() {
        Task(priority: .utility) {
            let pending = await songRepository.getSongsNeedingCopy()
            logger.debug("Found \(pending.count) songs needing copy verification")
        }
    }

    init() throws {
        var databaseName = "musicApp\(schemaVersion).sqlite"
        #if DEBUG
        if let testID = ProcessInfo.processInfo.environment["LOCALWAVE_UI_TEST_ID"], UUID(uuidString: testID) != nil {
            databaseName = "uitest-\(testID).sqlite"
        }
        #endif
        guard let db = setupSQLiteConnection(dbName: databaseName) else {
            throw CustomError.genericError("database initialisation failed")
        }

        let userRepo = try SQLiteUserRepository(db: db)
        let sourceRepo = try SQLiteSourceRepository(db: db)
        let sourcePathRepo = try SQLiteSourcePathRepository(db: db)
        self.sourcePathRepository = sourcePathRepo
        let sourcePathSearchRepository = try SQLiteSourcePathSearchRepository(db: db)
        self.sourcePathSearchRepository = sourcePathSearchRepository
        let songRepo = try SQLiteSongRepository(db: db)
        let access = SourceAccess(repository: sourceRepo, sourcePathRepository: sourcePathRepo, songRepository: songRepo)
        sourceAccess = access

        userService = DefaultUserService(userRepository: userRepo)
        icloudProvider = DefaultICloudProvider()
        userCloudService = DefaultUserCloudService(
            userService: userService,
            iCloudProvider: icloudProvider
        )

        let sourceSyncService = DefaultSourceSyncService(
            sourceRepository: sourceRepo,
            sourcePathSearchRepository: sourcePathSearchRepository,
            sourcePathRepository: sourcePathRepo,
            sourceAccess: access
        )

        let sourceImportService = DefaultSourceImportService(
            sourceRepository: sourceRepo,
            sourcePathRepository: sourcePathRepo,
            sourcePathSearchRepository: sourcePathSearchRepository
        )
        sourceService = DefaultSourceService(
            sourceRepo: sourceRepo,
            sourceSyncService: sourceSyncService,
            sourceImportService: sourceImportService
        )
        songRepository = songRepo
        songImportService = DefaultSongImportService(
            songRepo: songRepo,
            sourcePathRepo: sourcePathRepo,
            sourceRepo: sourceRepo,
            sourceAccess: access
        )
        playerPersistenceService = DefaultPlayerPersistenceService(songRepo: songRepo)
        playlistRepo = try SQLitePlaylistRepository(db: db)
        playlistSongRepo = try SQLitePlaylistSongRepository(db: db)
        backgroundFileService = BackgroundFileService(songRepo: songRepo, sourceAccess: access)
    }

    func makeSongListViewModel(filter: SongListViewModel.Filter) -> SongListViewModel {
        SongListViewModel(songRepo: songRepository, filter: filter)
    }

    func makeArtistListViewModel() -> ArtistListViewModel {
        ArtistListViewModel(songRepo: songRepository)
    }

    func makeAlbumListViewModel() -> AlbumListViewModel {
        AlbumListViewModel(songRepo: songRepository)
    }

    func makePlaylistListViewModel() -> PlaylistListViewModel {
        PlaylistListViewModel(
            playlistRepo: playlistRepo,
            playlistSongRepo: playlistSongRepo,
            songRepo: songRepository
        )
    }

    func makeSyncViewModel() -> SyncViewModel {
        SyncViewModel(
            userCloudService: userCloudService,
            icloudProvider: icloudProvider,
            sourceService: sourceService,
            songImportService: songImportService,
            sourceAccess: sourceAccess
        )
    }

    func resolveSourceAccess(for song: Song) async throws -> (root: URL, file: URL)? {
        if let sourceId = song.sourceId, let relativePath = song.relativePath {
            return try await sourceAccess.fileURL(sourceId: sourceId, relativePath: relativePath)
        }
        guard let user = try await userCloudService.resolveCurrentICloudUser(), let userID = user.id else { return nil }
        let sources = try await sourceService.repository().findOneByUserId(userId: userID, path: nil)
        for source in sources {
            guard let sourceID = source.id else { continue }
            guard let root = try? await sourceAccess.rootURL(sourceId: sourceID) else { continue }
            let paths = try await sourceService.importService().listItems(sourceId: sourceID, parentPathId: nil)
            guard let path = paths.first(where: { !$0.isDirectory && ($0.pathId == song.pathHash || makeURLHash(root.appendingPathComponent($0.relativePath)) == song.pathHash) }) else { continue }
            if let id = song.id { try await songRepository.updateSourceLocation(songId: id, sourceId: sourceID, relativePath: path.relativePath) }
            return (root, try SourceAccess.fileURL(root: root, relativePath: path.relativePath))
        }
        return nil
    }

    func reconnectSource(_ source: Source, to url: URL) async throws -> Source {
        guard let id = source.id else { throw CustomError.genericError("This music source was removed.") }
        return try await sourceAccess.reconnect(sourceId: id, to: url)
    }

    @discardableResult
    func addMusicURLs(_ urls: [URL], category: LWImportCategory = .music) async throws -> [Song] {
        var folders: [URL] = []
        var audio: [URL] = []
        var selectedFiles: [URL] = []
        let supported = MediaFileSupport.extensions
        for url in urls {
            guard url.isFileURL else { throw CustomError.genericError("Choose local files or folders from Files.") }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { folders.append(url) }
            else if supported.contains(url.pathExtension.lowercased()) { audio.append(url) }
            else { throw CustomError.genericError("Unsupported media file: \(url.lastPathComponent)") }
        }
        let selectedFolders = folders
        waveSyncViewModel.errorMessage = nil
        if !audio.isEmpty {
            let imported = try await Task.detached(priority: .userInitiated) { try Self.copyAudio(audio, category: category) }.value
            selectedFiles = imported.files
            try await importSelectedAddedFiles(imported.files, sourceDirectory: imported.folder, category: category)
        }
        for folder in folders {
            LWImportCategoryStore.set(category, for: folder.path)
            try waveSyncViewModel.registerBookmark(folder)
            waveSyncViewModel.createSource(path: folder.path)
        }
        await waveSyncViewModel.awaitPendingWork()
        if let error = waveSyncViewModel.errorMessage { throw CustomError.genericError(error) }
        var results: [Song] = []
        for file in selectedFiles {
            if let song = await songRepository.getSongByURL(file.resolvingSymlinksInPath()) { results.append(song) }
        }
        if let user = try await userCloudService.resolveCurrentICloudUser(), let id = user.id {
            for folder in selectedFolders {
                let sources = try await sourceService.repository().findOneByUserId(userId: id, path: folder.path)
                for source in sources {
                    guard let sourceID = source.id else { continue }
                    let paths = try await sourceService.importService().listItems(sourceId: sourceID, parentPathId: nil)
                    for path in paths.filter(\.isMedia).sorted(by: { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }) {
                        if let song = await songRepository.getSong(sourceId: sourceID, relativePath: path.relativePath) { results.append(song) }
                    }
                }
            }
        }
        var seen = Set<Int64>()
        return results.filter { seen.insert($0.uniqueId).inserted }
    }

    nonisolated static func copyAudio(_ urls: [URL], category: LWImportCategory = .music, destinationDirectory: URL? = nil) throws -> (folder: URL, files: [URL]) {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let addedFiles = destinationDirectory ?? documents.appendingPathComponent("Added Files", isDirectory: true)
            let folder = category == .music ? addedFiles : addedFiles.appendingPathComponent(category.title, isDirectory: true)
            var copied: [URL] = []
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let existingFiles = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])?.compactMap { $0 as? URL } ?? []
                let sourceSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                if let duplicate = existingFiles.first(where: { candidate in
                    guard (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
                    if let sourceSize, let candidateSize = try? candidate.resourceValues(forKeys: [.fileSizeKey]).fileSize, sourceSize != candidateSize { return false }
                    return FileManager.default.contentsEqual(atPath: url.path, andPath: candidate.path)
                }) {
                    copied.append(duplicate)
                    continue
                }
                var destination = folder.appendingPathComponent(url.lastPathComponent)
                if FileManager.default.fileExists(atPath: destination.path) {
                    if FileManager.default.contentsEqual(atPath: url.path, andPath: destination.path) { copied.append(destination); continue }
                    if let legacyCopy = existingFiles.first(where: { candidate in
                        guard let prefix = legacyCollisionPrefix(in: candidate.lastPathComponent, for: url.lastPathComponent), UUID(uuidString: prefix) != nil else { return false }
                        return (try? candidate.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                            && FileManager.default.contentsEqual(atPath: url.path, andPath: candidate.path)
                    }) {
                        let collisionFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                        try FileManager.default.createDirectory(at: collisionFolder, withIntermediateDirectories: true)
                        destination = collisionFolder.appendingPathComponent(url.lastPathComponent)
                        try FileManager.default.moveItem(at: legacyCopy, to: destination)
                        copied.append(destination)
                        continue
                    }
                    let collisionFolder = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: collisionFolder, withIntermediateDirectories: true)
                    destination = collisionFolder.appendingPathComponent(url.lastPathComponent)
                }
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                    let staging = folder.appendingPathComponent(".copy-" + UUID().uuidString)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    do {
                        try FileManager.default.copyItem(at: readableURL, to: staging)
                        try FileManager.default.moveItem(at: staging, to: destination)
                    } catch { copyError = error }
                }
                if let coordinationError { throw coordinationError }
                if let copyError { throw copyError }
                copied.append(destination)
            }
            return (folder, copied)
    }

    private func importSelectedAddedFiles(_ files: [URL], sourceDirectory: URL, category: LWImportCategory) async throws {
        guard !files.isEmpty else { return }
        let user = try await userCloudService.resolveCurrentICloudUser()
        guard let userID = user?.id else { throw CustomError.genericError("The music source is unavailable.") }
        try waveSyncViewModel.registerBookmark(sourceDirectory)
        LWImportCategoryStore.set(category, for: sourceDirectory.path)
        let source = try await sourceService.registerSourcePath(userId: userID, path: sourceDirectory.path, type: .iCloud)
        guard let sourceID = source.id else { throw CustomError.genericError("The music source could not be registered.") }
        if !waveSyncViewModel.sources.contains(where: { $0.id == sourceID }) { waveSyncViewModel.sources.append(source) }
        if let bookmark = LocalWavePreferences.current.data(forKey: makeBookmarkKey(sourceDirectory)) {
            _ = try await sourceService.repository().updateSourceBookmark(sourceId: sourceID, bookmark: bookmark, expectedBookmark: source.bookmark)
        }

        LocalWaveSelectedFilesSource.beginSelectionOnly(at: sourceDirectory)
        let relativePaths = try files.map { file -> String in
            guard let path = FileHelper(fileURL: file).relativePath(from: sourceDirectory) else {
                throw CustomError.genericError("The selected file is outside Added Files.")
            }
            return path
        }
        LocalWaveSelectedFilesSource.add(relativePaths, at: sourceDirectory)
        let selectedPaths = LocalWaveSelectedFilesSource.selectedRelativePaths(at: sourceDirectory)
        let runID = Int64.random(in: Int64.min...Int64.max)
        let rootPathID = source.pathId
        let now = Date()
        var paths = [SourcePath(id: nil, sourceId: sourceID, pathId: rootPathID,
            parentPathId: makeURLHash(sourceDirectory.deletingLastPathComponent()), name: sourceDirectory.lastPathComponent,
            relativePath: "", isDirectory: true, fileHashSHA256: nil, runId: runID, createdAt: now, updatedAt: nil)]
        var knownDirectories = Set<String>()
        var existingRelativePaths = Set<String>()
        for relativePath in selectedPaths.sorted() {
            let file = sourceDirectory.appendingPathComponent(relativePath)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let components = relativePath.split(separator: "/").map(String.init)
            guard let fileName = components.last else { continue }
            var parentRelativePath = ""
            var parentURL = sourceDirectory
            for directoryName in components.dropLast() {
                parentRelativePath = parentRelativePath.isEmpty ? directoryName : parentRelativePath + "/" + directoryName
                let directoryURL = sourceDirectory.appendingPathComponent(parentRelativePath, isDirectory: true)
                if knownDirectories.insert(parentRelativePath).inserted {
                    paths.append(SourcePath(id: nil, sourceId: sourceID, pathId: makeURLHash(directoryURL),
                        parentPathId: makeURLHash(parentURL), name: directoryName, relativePath: parentRelativePath,
                        isDirectory: true, fileHashSHA256: nil, runId: runID, createdAt: now, updatedAt: nil))
                }
                parentURL = directoryURL
            }
            let fileSize = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            paths.append(SourcePath(id: nil, sourceId: sourceID, pathId: makeURLHash(file),
                parentPathId: makeURLHash(parentURL), name: fileName, relativePath: relativePath,
                isDirectory: false, fileHashSHA256: nil, runId: runID, createdAt: now, updatedAt: nil, fileSize: fileSize))
            existingRelativePaths.insert(relativePath)
        }
        try await sourcePathRepository.batchUpsert(paths: paths)
        try await sourcePathSearchRepository.batchUpsertIntoFTS(paths: paths)
        _ = try await sourcePathRepository.deleteMany(sourceId: sourceID, excludingRunId: runID)
        try await sourcePathSearchRepository.batchDeleteFTS(sourceId: sourceID, excludingRunId: runID)
        _ = try await songRepository.deleteSongsMissingFromSource(sourceId: sourceID, relativePaths: existingRelativePaths)
        try await songImportService.importPaths(paths: Array(paths.dropFirst()), onProgress: nil)
        waveSyncViewModel.loadSources()
        NotificationCenter.default.post(name: Notification.Name("LibraryRefresh"), object: nil)
        NotificationCenter.default.post(name: Notification.Name("SongListRefresh"), object: nil)
    }

    private nonisolated static func legacyCollisionPrefix(in candidateName: String, for originalName: String) -> String? {
        let suffix = "-" + originalName
        guard candidateName.hasSuffix(suffix) else { return nil }
        return String(candidateName.dropLast(suffix.count))
    }

    private func startBackgroundServices() {
        logger.debug("starting background service...")
        guard let service = backgroundFileService else {
            logger.error("failed to initialise background file service")
            return
        }

        Task {
            await service.start()
            logger.debug("background file service startup triggered")
        }
    }
}
