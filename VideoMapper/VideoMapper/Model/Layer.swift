import CoreGraphics
import Foundation

/// A media file that has been imported into the project's own storage.
///
/// Projects reference media by relative filename so a project folder can be copied
/// between devices (or shared over AirDrop) without breaking its links.
struct MediaReference: Codable, Equatable, Hashable, Identifiable {
    enum Kind: String, Codable { case image, video }

    var id: UUID = UUID()
    var kind: Kind
    /// Filename inside the project's `Media` directory.
    var filename: String
    var displayName: String
    /// Natural pixel size, used to preserve aspect ratio when a layer is created.
    var pixelSize: CGSize
    /// Video duration in seconds; zero for stills.
    var duration: Double = 0
}

/// Per-layer video transport options.
struct VideoPlayback: Codable, Equatable {
    var loops: Bool = true
    var rate: Double = 1
    var volume: Double = 0
    /// Offset into the clip that lines up with show time zero.
    var startOffset: Double = 0
    /// When true the clip is locked to the show clock and is continuously
    /// drift-corrected, so every device shows the same frame.
    var followsShowClock: Bool = true
}

/// What a layer draws.
enum LayerContent: Codable, Equatable {
    case solid
    case image(MediaReference)
    case video(MediaReference, VideoPlayback)

    var media: MediaReference? {
        switch self {
        case .solid: return nil
        case .image(let ref): return ref
        case .video(let ref, _): return ref
        }
    }

    var displayName: String {
        switch self {
        case .solid: return "Colour"
        case .image(let ref): return ref.displayName
        case .video(let ref, _): return ref.displayName
        }
    }

    var isVideo: Bool { if case .video = self { return true }; return false }
}

/// Position, size and warp of a layer.
///
/// Size/rotation/centre stay separate from the four corner offsets so the simple
/// controls (a size slider) keep working after the quad has been warped by hand.
struct LayerTransform: Codable, Equatable {
    /// Centre in normalized canvas space.
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    /// Size as a fraction of the canvas.
    var size: CGSize = CGSize(width: 0.6, height: 0.6)
    /// Clockwise rotation in radians.
    var rotation: Double = 0
    /// Free-form corner pins, added after rotation, in normalized canvas units.
    var cornerOffsets: [CGPoint] = Array(repeating: .zero, count: 4)

    /// The mapped quad, with an optional uniform scale applied last (used by
    /// audio modulation so reactive scaling never overwrites the stored size).
    func quad(scale: Double = 1) -> Quad {
        let hw = size.width * scale / 2
        let hh = size.height * scale / 2
        let local = [CGPoint(x: -hw, y: -hh), CGPoint(x: hw, y: -hh),
                     CGPoint(x: hw, y: hh), CGPoint(x: -hw, y: hh)]
        let cosR = cos(rotation), sinR = sin(rotation)
        var quad = Quad.unit
        for i in 0..<4 {
            let p = local[i]
            let rotated = CGPoint(x: p.x * cosR - p.y * sinR, y: p.x * sinR + p.y * cosR)
            let offset = i < cornerOffsets.count ? cornerOffsets[i] : .zero
            quad[i] = CGPoint(x: center.x + rotated.x + offset.x,
                              y: center.y + rotated.y + offset.y)
        }
        return quad
    }

    /// Rewrites `cornerOffsets` so the mapped quad passes through `point` at `index`,
    /// leaving centre/size/rotation untouched.
    mutating func setCorner(_ index: Int, to point: CGPoint) {
        guard (0..<4).contains(index) else { return }
        var zeroed = self
        zeroed.cornerOffsets = Array(repeating: .zero, count: 4)
        let base = zeroed.quad()[index]
        if cornerOffsets.count < 4 { cornerOffsets = Array(repeating: .zero, count: 4) }
        cornerOffsets[index] = point - base
    }

    mutating func resetWarp() {
        cornerOffsets = Array(repeating: .zero, count: 4)
    }

    var isWarped: Bool {
        cornerOffsets.contains { $0.x != 0 || $0.y != 0 }
    }
}

/// One element of the projection: a piece of media, where it lands, and how it looks.
struct MappingLayer: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var isVisible: Bool = true
    /// Locked layers ignore stage gestures, so a finished mapping cannot be nudged.
    var isLocked: Bool = false
    var content: LayerContent = .solid
    var transform: LayerTransform = LayerTransform()
    var appearance: Appearance = Appearance()
    var modulation: [ModulationRoute] = []

    init(id: UUID = UUID(), name: String, content: LayerContent = .solid) {
        self.id = id
        self.name = name
        self.content = content
        if case .solid = content {
            appearance.tint = RGBAColor(red: 1, green: 1, blue: 1)
            appearance.tintAmount = 1
        }
    }

    /// Creates a layer sized to the media's aspect ratio inside a canvas of `canvasAspect`.
    static func make(from ref: MediaReference, canvasAspect: Double) -> MappingLayer {
        let content: LayerContent = ref.kind == .video ? .video(ref, VideoPlayback()) : .image(ref)
        var layer = MappingLayer(name: ref.displayName, content: content)
        let mediaAspect = ref.pixelSize.height > 0
            ? Double(ref.pixelSize.width / ref.pixelSize.height)
            : canvasAspect
        // Fit the media inside 70% of the canvas without distorting it.
        let relative = mediaAspect / canvasAspect
        var w = 0.7, h = 0.7
        if relative >= 1 { h = 0.7 / relative } else { w = 0.7 * relative }
        layer.transform.size = CGSize(width: w, height: h)
        return layer
    }
}
