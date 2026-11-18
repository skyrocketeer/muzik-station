#if os(iOS) || os(macOS)
import LocalWaveData
import LocalWaveCore
import LocalWaveDomain
//
//  SongMetadataEditorView.swift
//  localwave
//
//  Created by Oleg Pustovit on 20.05.2025.
//

import AVFoundation
import Combine
import MediaPlayer
import os
import SwiftUI
import UniformTypeIdentifiers
import ImageIO
#if os(iOS)
import PhotosUI
#endif

struct SongMetadataEditorView: View {
    @Environment(\.dismiss) var dismiss
    let song: Song
    let songRepo: SongRepository
    @State private var title: String
    @State private var artist: String
    @State private var album: String
    @State private var albumArtist: String
    @State private var releaseYear: String
    @State private var discNumber: String
    @State private var trackNumber: String
    @State private var coverArtPath: String?
    @State private var lyrics: String
    @State private var importingCover = false
    @State private var importingLyrics = false
    @State private var coverError: String?
    @State private var importError: String?
#if os(iOS)
    @State private var selectedPhoto: PhotosPickerItem?
#endif

    private let logger = Logger(subsystem: subsystem, category: "SongMetadataEditorView")

    init(song: Song, songRepo: SongRepository) {
        self.song = song
        self.songRepo = songRepo
        _title = State(initialValue: song.title)
        _artist = State(initialValue: song.artist)
        _album = State(initialValue: song.album)
        _albumArtist = State(initialValue: song.albumArtist)
        _releaseYear = State(initialValue: song.releaseYear != nil ? "\(song.releaseYear!)" : "")
        _discNumber = State(initialValue: song.discNumber != nil ? "\(song.discNumber!)" : "")
        _trackNumber = State(initialValue: song.trackNumber != nil ? "\(song.trackNumber!)" : "")
        _coverArtPath = State(initialValue: song.coverArtPath)
        _lyrics = State(initialValue: song.lyrics ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Cover Photo")) {
                    HStack(spacing: 14) {
                        LWArtwork(song: songWithCover(coverArtPath), size: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        VStack(alignment: .leading, spacing: 8) {
                            Text(coverArtPath == nil ? "Album artwork" : "Custom artwork")
                                .font(LWTheme.text(14)).foregroundStyle(LWTheme.secondary)
                            HStack(spacing: 12) {
#if os(iOS)
                                PhotosPicker(selection: $selectedPhoto, matching: .images) { Text("Photos") }
#endif
                                Button("Files…") { importingCover = true }
                            }
                            if coverArtPath != nil {
                                Button("Remove Photo", role: .destructive) { coverArtPath = nil }
                            }
                        }
                    }.padding(.vertical, 4)
                }
                Section(header: Text("Basic Info")) {
                    TextField("Title", text: $title)
                    TextField("Artist", text: $artist)
                    TextField("Album", text: $album)
                    TextField("Album Artist", text: $albumArtist)
                }
                Section(header: Text("Additional Info")) {
                    TextField("Release Year", text: $releaseYear)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                    TextField("Disc Number", text: $discNumber)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                    TextField("Track Number", text: $trackNumber)
#if os(iOS)
                        .keyboardType(.numberPad)
#endif
                }
                Section(header: Text("Lyrics"), footer: Text("Import an SRT file. Timed lines appear over the artwork during playback.")) {
                    Button(lyrics.isEmpty ? "Import SRT…" : "Replace SRT…") { importingLyrics = true }
                    if !lyrics.isEmpty {
                        Text("\(srtCueCount(lyrics)) timed lines imported").font(LWTheme.text(13)).foregroundStyle(LWTheme.secondary)
                        Button("Remove Lyrics", role: .destructive) { lyrics = "" }
                    }
                }
            }
            .fileImporter(isPresented: $importingCover, allowedContentTypes: [.image], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    coverArtPath = try storeCoverArt(url)
                    coverError = nil
                } catch { coverError = error.localizedDescription }
            }
            .fileImporter(isPresented: $importingLyrics, allowedContentTypes: [UTType(filenameExtension: "srt") ?? .plainText], allowsMultipleSelection: false) { result in
                do {
                    guard let url = try result.get().first else { return }
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    var coordinationError: NSError?
                    var readResult: Result<Data, Error>?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
                        readResult = Result { try Data(contentsOf: readable) }
                    }
                    if let coordinationError { throw coordinationError }
                    guard let data = try readResult?.get(), let text = String(data: data, encoding: .utf8), srtCueCount(text) > 0 else {
                        throw NSError(domain: "PowerMusicStationLyrics", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a valid SRT lyrics file."])
                    }
                    lyrics = text
                    importError = nil
                } catch { importError = error.localizedDescription }
            }
#if os(iOS)
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                Task {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                        coverArtPath = try storeCoverArt(data: data, fileExtension: "jpg")
                        coverError = nil
                    } catch { coverError = error.localizedDescription }
                }
            }
#endif
            .alert("Unable to add cover photo", isPresented: Binding(get: { coverError != nil }, set: { if !$0 { coverError = nil } })) {
                Button("OK") { coverError = nil }
            } message: { Text(coverError ?? "") }
            .alert("Unable to import lyrics", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK") { importError = nil }
            } message: { Text(importError ?? "") }
            .navigationTitle("Edit Metadata")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            let updatedSong = Song(
                                id: song.id,
                                songKey: song.songKey,
                                artist: artist,
                                title: title,
                                album: album,
                                albumArtist: albumArtist,
                                releaseYear: Int(releaseYear),
                                discNumber: Int(discNumber),
                                trackNumber: Int(trackNumber),
                                coverArtPath: coverArtPath,
                                bookmark: song.bookmark,
                                pathHash: song.pathHash,
                                createdAt: song.createdAt,
                                updatedAt: Date(),
                                localFilePath: song.localFilePath,
                                fileState: song.fileState,
                                isFavorite: song.isFavorite,
                                sourceId: song.sourceId,
                                relativePath: song.relativePath,
                                duration: song.duration,
                                fileSize: song.fileSize,
                                fileExtension: song.fileExtension,
                                sampleRate: song.sampleRate,
                                bitDepth: song.bitDepth,
                                sourceAvailability: song.sourceAvailability,
                                lyrics: song.lyrics
                            )
                            do {
                                _ = try await songRepo.upsertSong(updatedSong)
                                if let id = song.id {
                                    let trimmedLyrics = lyrics.trimmingCharacters(in: .whitespacesAndNewlines)
                                    try await songRepo.updateLyrics(songId: id, lyrics: trimmedLyrics.isEmpty ? nil : lyrics)
                                }
                                NotificationCenter.default.post(name: Notification.Name("LibraryRefresh"), object: nil)
                                NotificationCenter.default.post(
                                    name: Notification.Name("SongListRefresh"), object: nil
                                )
                                dismiss()
                            } catch {
                                logger.error("failed to upsert: \(error)")
                            }
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func songWithCover(_ path: String?) -> Song {
        Song(id: song.id, songKey: song.songKey, artist: song.artist, title: song.title, album: song.album,
             albumArtist: song.albumArtist, releaseYear: song.releaseYear, discNumber: song.discNumber,
             trackNumber: song.trackNumber, coverArtPath: path, bookmark: song.bookmark, pathHash: song.pathHash,
             createdAt: song.createdAt, updatedAt: song.updatedAt, localFilePath: song.localFilePath,
             fileState: song.fileState, isFavorite: song.isFavorite, sourceId: song.sourceId,
             relativePath: song.relativePath, duration: song.duration, fileSize: song.fileSize,
             fileExtension: song.fileExtension, sampleRate: song.sampleRate, bitDepth: song.bitDepth,
             sourceAvailability: song.sourceAvailability, lyrics: song.lyrics)
    }

    private func storeCoverArt(_ url: URL) throws -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size <= 25 * 1_048_576 else {
            throw NSError(domain: "MusicStationCoverArt", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an image smaller than 25 MB."])
        }
        var coordinationError: NSError?
        var readResult: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
            readResult = Result { try Data(contentsOf: readable) }
        }
        if let coordinationError { throw coordinationError }
        guard let data = try readResult?.get() else { throw CocoaError(.fileReadCorruptFile) }
        return try storeCoverArt(data: data, fileExtension: url.pathExtension)
    }

    private func storeCoverArt(data: Data, fileExtension: String) throws -> String {
        guard data.count <= 25 * 1_048_576,
              let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            throw NSError(domain: "MusicStationCoverArt", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected file is not a readable image."])
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("CoverArt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = fileExtension.lowercased().isEmpty ? "img" : fileExtension.lowercased()
        let name = "custom-\(UUID().uuidString).\(ext)"
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return "CoverArt/\(name)"
    }

    private func srtCueCount(_ text: String) -> Int {
        text.components(separatedBy: .newlines).filter { line in
            let parts = line.components(separatedBy: " --> ")
            return parts.count == 2 && srtTime(parts[0]) != nil && srtTime(parts[1]) != nil
        }.count
    }

    private func srtTime(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

#endif
