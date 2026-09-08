import Metal
import MetalKit
import os

/// Owns the GPU-side resources for every layer and keeps them in step with the project.
///
/// Sources are keyed by layer id and rebuilt only when a layer's *content* changes,
/// so adjusting sliders never re-decodes a video. Reconciliation happens on the main
/// thread; the draw thread only reads, guarded by a lock.
final class TextureStore {
    private let device: MTLDevice
    private let log = Logger(subsystem: "app.videomapper", category: "TextureStore")
    private let lock = NSLock()

    private var sources: [UUID: TextureSource] = [:]
    /// Content fingerprints, so we can tell a genuine media swap from a slider move.
    private var signatures: [UUID: String] = [:]
    private var overlays: [UUID: MTLTexture] = [:]
    private var solid: SolidTextureSource
    private var projectID: UUID?

    init(device: MTLDevice) {
        self.device = device
        self.solid = SolidTextureSource(device: device)
    }

    private func signature(for content: LayerContent) -> String {
        switch content {
        case .solid: return "solid"
        case .image(let ref): return "image:\(ref.filename)"
        case .video(let ref, _): return "video:\(ref.filename)"
        }
    }

    /// Creates sources for new layers, releases them for deleted ones, and pushes
    /// changed playback settings into existing video sources.
    @MainActor
    func reconcile(project: MappingProject) {
        let store = ProjectStore.shared
        lock.lock()
        defer { lock.unlock() }

        if projectID != project.id {
            sources.removeAll()
            signatures.removeAll()
            overlays.removeAll()
            projectID = project.id
        }

        var live = Set<UUID>()
        for layer in project.layers {
            live.insert(layer.id)
            let signature = signature(for: layer.content)

            if signatures[layer.id] != signature {
                sources[layer.id] = makeSource(for: layer, projectID: project.id, store: store)
                signatures[layer.id] = signature
            } else if case .video(_, let playback) = layer.content,
                      let video = sources[layer.id] as? VideoTextureSource {
                video.update(playback: playback)
            }

            if let image = layer.appearance.texture.image, overlays[image.id] == nil {
                let url = store.mediaURL(for: image, projectID: project.id)
                overlays[image.id] = ImageTextureSource(url: url, device: device)
                    .texture(showTime: 0, isPlaying: false)
            }
        }

        for id in sources.keys where !live.contains(id) {
            sources.removeValue(forKey: id)
            signatures.removeValue(forKey: id)
        }

        let liveOverlays = Set(project.layers.compactMap { $0.appearance.texture.image?.id })
        for id in overlays.keys where !liveOverlays.contains(id) {
            overlays.removeValue(forKey: id)
        }
    }

    private func makeSource(for layer: MappingLayer, projectID: UUID, store: ProjectStore) -> TextureSource {
        switch layer.content {
        case .solid:
            return solid
        case .image(let ref):
            return ImageTextureSource(url: store.mediaURL(for: ref, projectID: projectID), device: device)
        case .video(let ref, let playback):
            let url = store.mediaURL(for: ref, projectID: projectID)
            if let video = VideoTextureSource(url: url, playback: playback,
                                              duration: ref.duration, device: device) {
                return video
            }
            log.error("Falling back to solid; could not open \(ref.filename, privacy: .public)")
            return solid
        }
    }

    func sourceTexture(for layer: ResolvedLayer, showTime: Double, isPlaying: Bool) -> MTLTexture? {
        lock.lock()
        let source = sources[layer.id]
        lock.unlock()
        return source?.texture(showTime: showTime, isPlaying: isPlaying)
    }

    func overlayTexture(for layer: ResolvedLayer) -> MTLTexture? {
        guard let id = layer.appearance.texture.image?.id else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return overlays[id]
    }
}
