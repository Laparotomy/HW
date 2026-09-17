import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Preview images for whatever a layer is showing.
///
/// A layer list that reads "Colour · Screen · warped" tells you nothing about what is
/// on the wall. These are the thumbnails that make a stack of mappings identifiable
/// at a glance, and they are what the inspector shows before you commit to swapping a
/// layer's content.
@MainActor
final class ContentThumbnailStore: ObservableObject {
    static let shared = ContentThumbnailStore()

    /// Wide enough to recognise a clip, small enough that a list of them costs
    /// nothing to keep resident.
    private static let maximumDimension = 240

    /// Keyed by content signature rather than layer id, so duplicating a layer or
    /// reusing a clip does not decode it twice.
    @Published private var images: [String: CGImage] = [:]
    private var inFlight: Set<String> = []

    private init() {}

    /// A stable key for the thing being drawn. Generator settings are part of it:
    /// change the palette and the preview should follow.
    static func signature(for content: LayerContent) -> String? {
        switch content {
        case .solid:
            return nil
        case .image(let ref):
            return "image:\(ref.filename)"
        case .video(let ref, _):
            return "video:\(ref.filename)"
        case .generator(let kind, let settings):
            return "generator:\(kind.rawValue):\(settings.palette.rawValue)"
        }
    }

    /// Returns a preview if one is ready, and starts decoding if not.
    ///
    /// Deliberately synchronous-with-a-nil: SwiftUI calls this from `body`, so it has
    /// to answer immediately. The published dictionary re-renders the view when the
    /// real image lands.
    func image(for content: LayerContent, projectID: UUID) -> CGImage? {
        guard let key = Self.signature(for: content) else { return nil }
        if let ready = images[key] { return ready }

        switch content {
        case .solid:
            return nil
        case .generator(let kind, let settings):
            // Generated on the GPU in well under a frame, so there is no reason to
            // make the caller wait a render pass for it.
            guard let image = GeneratorThumbnailRenderer.shared.image(for: kind,
                                                                     palette: settings.palette)
            else { return nil }
            images[key] = image
            return image
        case .image(let ref), .video(let ref, _):
            load(ref: ref, key: key, projectID: projectID)
            return nil
        }
    }

    /// Drops previews for media the project no longer references.
    func prune(keeping signatures: Set<String>) {
        images = images.filter { signatures.contains($0.key) }
    }

    private func load(ref: MediaReference, key: String, projectID: UUID) {
        guard !inFlight.contains(key) else { return }
        inFlight.insert(key)
        let url = ProjectStore.shared.mediaURL(for: ref, projectID: projectID)
        let kind = ref.kind
        let maximum = Self.maximumDimension

        Task.detached(priority: .utility) {
            let image = kind == .video
                ? await Self.videoFrame(at: url, maximum: maximum)
                : Self.stillImage(at: url, maximum: maximum)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inFlight.remove(key)
                if let image { self.images[key] = image }
            }
        }
    }

    /// Downsampled while decoding rather than after: a 4K still decoded at full size
    /// just to be shrunk is tens of megabytes per layer.
    private nonisolated static func stillImage(at url: URL, maximum: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximum
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// A frame from a little way in, not from time zero — clips often open on black,
    /// and a black thumbnail is no more use than none.
    private nonisolated static func videoFrame(at url: URL, maximum: Int) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximum, height: maximum)
        // A generous tolerance keeps this on keyframes, which is far cheaper than
        // decoding forward to an exact time nobody will notice.
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        return try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image
    }
}
