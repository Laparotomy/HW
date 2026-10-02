import AVFoundation
import MediaPlayer
import SwiftUI

/// Picks a track from the music already on the device.
///
/// `MPMediaPickerController` is the only way in: there is no public API that reads
/// the Apple Music catalogue as audio, and no third-party playback SDK for
/// SoundCloud, Spotify or YouTube on iOS. What this reaches is the library — songs
/// you bought or synced, and Apple Music songs you downloaded. See
/// `MediaImporter.MusicImportError.protectedByDRM` for what happens to the ones
/// that are encrypted, and Listen mode for everything this cannot open at all.
struct MusicLibraryPicker: UIViewControllerRepresentable {
    var onPick: (MPMediaItem) -> Void
    var onCancel: () -> Void

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        // Cloud items are shown so the list matches what the Music app shows. Ones
        // that are not downloaded have no asset and are reported as such, which is
        // more useful than silently hiding half of someone's library.
        picker.showsCloudItems = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        private let parent: MusicLibraryPicker

        init(_ parent: MusicLibraryPicker) { self.parent = parent }

        func mediaPicker(_ mediaPicker: MPMediaPickerController,
                         didPickMediaItems collection: MPMediaItemCollection) {
            guard let item = collection.items.first else {
                parent.onCancel()
                return
            }
            parent.onPick(item)
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            parent.onCancel()
        }
    }
}

extension MediaImporter {

    enum MusicImportError: LocalizedError {
        case notAuthorised
        case protectedByDRM
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorised:
                return "Video Mapper needs access to your music library. Turn it on in "
                    + "Settings › Privacy › Media & Apple Music."
            case .protectedByDRM:
                return "That track is protected and cannot be read by another app. Play "
                    + "it from the Music app and switch the clock to Listen — the "
                    + "microphone follows it just as well."
            case .exportFailed(let reason):
                return "That track could not be copied: \(reason)"
            }
        }
    }

    /// Asks for the music library, returning whether it was granted.
    static func requestMusicLibraryAccess() async -> Bool {
        let status = MPMediaLibrary.authorizationStatus()
        if status == .authorized { return true }
        guard status == .notDetermined else { return false }
        return await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Copies a library track into the project's own folder.
    ///
    /// The copy is not a nicety. Analysis reads the file with `AVAudioFile`, which
    /// cannot open an `ipod-library://` URL, and a show that has to play in step on
    /// several phones needs the audio to be a file each of them holds. So the track
    /// is exported to m4a first, and a track that refuses to export is one this app
    /// genuinely cannot use.
    static func importMusicLibraryItem(_ item: MPMediaItem, projectID: UUID) async throws -> MediaReference {
        // Nil for anything the device does not hold in the clear: an Apple Music
        // stream, a download still encrypted, a track not downloaded at all.
        guard let assetURL = item.assetURL else { throw MusicImportError.protectedByDRM }

        let asset = AVURLAsset(url: assetURL)
        guard let session = AVAssetExportSession(asset: asset,
                                                 presetName: AVAssetExportPresetAppleM4A) else {
            throw MusicImportError.exportFailed("this device cannot convert it.")
        }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: output) }
        try await runExport(session, to: output)

        let duration = try await CMTimeGetSeconds(AVURLAsset(url: output).load(.duration))
        let title = [item.title, item.artist].compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return try ProjectStore.shared.importMedia(
            from: output, kind: .video,
            displayName: title.isEmpty ? "Track" : title,
            pixelSize: .zero, duration: duration.isFinite ? duration : 0,
            projectID: projectID)
    }

    private static func runExport(_ session: AVAssetExportSession, to url: URL) async throws {
        if #available(iOS 18.0, *) {
            do {
                try await session.export(to: url, as: .m4a)
            } catch {
                throw MusicImportError.exportFailed(error.localizedDescription)
            }
        } else {
            try await legacyExport(session, to: url)
        }
    }

    /// Carries the export session into its own completion handler.
    ///
    /// `exportAsynchronously` takes a `@Sendable` closure, and `AVAssetExportSession`
    /// is not `Sendable` — so reading the session's own status from its own callback
    /// is rejected under strict concurrency, even though that is the documented way to
    /// use the API. The box is sound rather than a silencer: the session is used from
    /// one place at a time, and the callback is where the framework itself says its
    /// status is ready to read.
    private struct ExportSession: @unchecked Sendable {
        let session: AVAssetExportSession
    }

    /// The pre-iOS 18 export. Marked deprecated itself so calling the deprecated API
    /// from inside it is not a warning.
    @available(iOS, introduced: 17.0, deprecated: 18.0,
               message: "Superseded by AVAssetExportSession.export(to:as:).")
    private static func legacyExport(_ session: AVAssetExportSession, to url: URL) async throws {
        session.outputURL = url
        session.outputFileType = .m4a
        let boxed = ExportSession(session: session)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            boxed.session.exportAsynchronously {
                switch boxed.session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: MusicImportError.exportFailed("the copy was cancelled."))
                default:
                    let reason = boxed.session.error?.localizedDescription
                        ?? "the reason was not reported."
                    continuation.resume(throwing: MusicImportError.exportFailed(reason))
                }
            }
        }
    }
}
