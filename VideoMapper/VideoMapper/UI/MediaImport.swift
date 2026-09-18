import AVFoundation
import CoreTransferable
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

/// A movie pulled out of the photo picker.
///
/// Videos are moved as files rather than `Data`: a few minutes of 4K would be
/// hundreds of megabytes, and loading that into memory to write it straight back
/// out is a good way to get the app jetsammed.
struct TransferableMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension.isEmpty ? "mov" : received.file.pathExtension
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return TransferableMovie(url: copy)
        }
    }
}

/// Brings files from the photo library or the Files app into a project's own folder.
enum MediaImporter {
    private static let log = Logger(subsystem: "app.videomapper", category: "Import")

    /// Imports one picked photo-library item.
    static func importItem(_ item: PhotosPickerItem, projectID: UUID) async throws -> MediaReference {
        let isVideo = item.supportedContentTypes.contains { $0.conforms(to: .movie) }
        let name = item.itemIdentifier.map { String($0.prefix(8)) } ?? "Clip"

        if isVideo {
            guard let movie = try await item.loadTransferable(type: TransferableMovie.self) else {
                throw ImportError.unreadable
            }
            defer { try? FileManager.default.removeItem(at: movie.url) }
            return try await importVideo(at: movie.url, displayName: "Video \(name)", projectID: projectID)
        }

        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ImportError.unreadable
        }
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("png")
        guard let image = UIImage(data: data), let png = image.pngData() else {
            throw ImportError.unreadable
        }
        try png.write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        return try ProjectStore.shared.importMedia(from: temporary, kind: .image,
                                                   displayName: "Image \(name)",
                                                   pixelSize: image.size, duration: 0,
                                                   projectID: projectID)
    }

    /// Imports a movie file, reading its true dimensions so the layer starts undistorted.
    static func importVideo(at url: URL, displayName: String, projectID: UUID) async throws -> MediaReference {
        let asset = AVURLAsset(url: url)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        var pixelSize = CGSize(width: 1920, height: 1080)
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            // Apply the display transform so portrait footage is not reported landscape.
            let transformed = natural.applying(transform)
            pixelSize = CGSize(width: abs(transformed.width), height: abs(transformed.height))
        }
        return try ProjectStore.shared.importMedia(from: url, kind: .video, displayName: displayName,
                                                   pixelSize: pixelSize,
                                                   duration: duration.isFinite ? duration : 0,
                                                   projectID: projectID)
    }

    /// Imports a file chosen through the Files app (used for audio and for media
    /// that never went through the photo library).
    static func importSecurityScopedFile(at url: URL, kind: MediaReference.Kind,
                                         projectID: UUID) async throws -> MediaReference {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }

        switch kind {
        case .video:
            return try await importVideo(at: url, displayName: url.deletingPathExtension().lastPathComponent,
                                         projectID: projectID)
        case .image:
            let image = UIImage(contentsOfFile: url.path)
            return try ProjectStore.shared.importMedia(
                from: url, kind: .image,
                displayName: url.deletingPathExtension().lastPathComponent,
                pixelSize: image?.size ?? CGSize(width: 1024, height: 1024),
                duration: 0, projectID: projectID)
        }
    }

    /// Imports an audio track. Stored with `.video` kind semantics off; duration is
    /// read so devices can verify they hold the same file.
    static func importAudio(at url: URL, projectID: UUID) async throws -> MediaReference {
        let needsAccess = url.startAccessingSecurityScopedResource()
        defer { if needsAccess { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let duration = try await CMTimeGetSeconds(asset.load(.duration))
        return try ProjectStore.shared.importMedia(
            from: url, kind: .video,
            displayName: url.deletingPathExtension().lastPathComponent,
            pixelSize: .zero, duration: duration.isFinite ? duration : 0,
            projectID: projectID)
    }

    enum ImportError: LocalizedError {
        case unreadable
        var errorDescription: String? { "That file could not be read." }
    }
}
