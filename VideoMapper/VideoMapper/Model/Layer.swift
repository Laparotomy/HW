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
    /// Per-layer speed range. Zero freezes the clip on its start frame; 4x is as fast
    /// as AVPlayer will run a file without stuttering on a phone.
    static let rateRange: ClosedRange<Double> = 0...4

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
    /// A procedural abstract source, synthesised in the shader. Carries no media,
    /// so a project using generators stays a few kilobytes of JSON.
    case generator(GeneratorKind, GeneratorSettings)

    var media: MediaReference? {
        switch self {
        case .solid, .generator: return nil
        case .image(let ref): return ref
        case .video(let ref, _): return ref
        }
    }

    var displayName: String {
        switch self {
        case .solid: return "Colour"
        case .image(let ref): return ref.displayName
        case .video(let ref, _): return ref.displayName
        case .generator(let kind, _): return kind.displayName
        }
    }

    var isVideo: Bool { if case .video = self { return true }; return false }

    var isSolid: Bool { if case .solid = self { return true }; return false }

    var generator: (kind: GeneratorKind, settings: GeneratorSettings)? {
        if case .generator(let kind, let settings) = self { return (kind, settings) }
        return nil
    }
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
    /// Extra correction points inside the quad, for surfaces four corners cannot
    /// describe. Defaults to a single cell, which behaves exactly like no mesh.
    var mesh: MeshWarp = MeshWarp()

    init(center: CGPoint = CGPoint(x: 0.5, y: 0.5),
         size: CGSize = CGSize(width: 0.6, height: 0.6),
         rotation: Double = 0,
         cornerOffsets: [CGPoint] = Array(repeating: .zero, count: 4),
         mesh: MeshWarp = MeshWarp()) {
        self.center = center
        self.size = size
        self.rotation = rotation
        self.cornerOffsets = cornerOffsets
        self.mesh = mesh
    }

    /// Decoded field by field with defaults so a show saved before a field existed
    /// still opens. A synthesised decoder would reject the older file outright.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        center = try container.decodeIfPresent(CGPoint.self, forKey: .center)
            ?? CGPoint(x: 0.5, y: 0.5)
        size = try container.decodeIfPresent(CGSize.self, forKey: .size)
            ?? CGSize(width: 0.6, height: 0.6)
        rotation = try container.decodeIfPresent(Double.self, forKey: .rotation) ?? 0
        let corners = try container.decodeIfPresent([CGPoint].self, forKey: .cornerOffsets) ?? []
        cornerOffsets = corners.count == 4
            ? corners
            : Array(corners.prefix(4)) + Array(repeating: .zero, count: max(0, 4 - corners.count))
        mesh = try container.decodeIfPresent(MeshWarp.self, forKey: .mesh) ?? MeshWarp()
    }

    private enum CodingKeys: String, CodingKey {
        case center, size, rotation, cornerOffsets, mesh
    }

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
        mesh.reset()
    }

    var isWarped: Bool {
        cornerOffsets.contains { $0.x != 0 || $0.y != 0 } || mesh.isWarped
    }

    // MARK: - Mesh

    /// Control point positions in canvas space.
    ///
    /// The base position of a point is the quad's own projective map of its (u, v) —
    /// not a bilinear interpolation of the corners. That is what makes an unwarped
    /// mesh invisible: every point already sits exactly where the homography puts it,
    /// so adding points to a finished mapping does not shift the image by a pixel.
    func meshPoints(scale: Double = 1) -> [CGPoint] {
        let matrix = Homography.unitSquare(to: quad(scale: scale))
        var points: [CGPoint] = []
        points.reserveCapacity(mesh.pointCount)
        for row in 0...mesh.rows {
            for column in 0...mesh.columns {
                let parameter = mesh.parameter(column: column, row: row)
                let base = Homography.apply(matrix, to: parameter)
                let offset = mesh.effectiveOffset(at: mesh.index(column: column, row: row))
                points.append(CGPoint(x: base.x + offset.x, y: base.y + offset.y))
            }
        }
        return points
    }

    /// The layer broken into drawable cells, each with the slice of the layer's
    /// texture that belongs to it. A 1 x 1 mesh yields exactly one cell covering the
    /// whole quad, which is the un-subdivided case.
    func meshCells(scale: Double = 1) -> [MeshCell] {
        guard mesh.isSubdivided else {
            return [MeshCell(quad: quad(scale: scale), uvOrigin: .zero,
                             uvSize: CGSize(width: 1, height: 1))]
        }

        let points = meshPoints(scale: scale)
        let across = mesh.pointsAcross
        let cellWidth = 1.0 / Double(mesh.columns)
        let cellHeight = 1.0 / Double(mesh.rows)

        var cells: [MeshCell] = []
        cells.reserveCapacity(mesh.cellCount)
        for row in 0..<mesh.rows {
            for column in 0..<mesh.columns {
                let topLeft = row * across + column
                // Quad corner order is (0,0), (1,0), (1,1), (0,1).
                let quad = Quad(p00: points[topLeft],
                                p10: points[topLeft + 1],
                                p11: points[topLeft + across + 1],
                                p01: points[topLeft + across])
                cells.append(MeshCell(
                    quad: quad,
                    uvOrigin: CGPoint(x: Double(column) * cellWidth,
                                      y: Double(row) * cellHeight),
                    uvSize: CGSize(width: cellWidth, height: cellHeight)))
            }
        }
        return cells
    }

    /// Rewrites the *hand* offset of a control point so it lands on `position`.
    ///
    /// Any scan correction on that point stays in place and is measured around: drag
    /// a handle on a bent layer and it goes where the finger is, while re-running the
    /// bend still recomputes only its own share.
    mutating func setMeshPoint(_ index: Int, to position: CGPoint, scale: Double = 1) {
        guard (0..<mesh.pointCount).contains(index) else { return }
        var probe = self
        probe.mesh.setOffset(.zero, at: index)
        let base = probe.meshPoints(scale: scale)[index]
        mesh.setOffset(CGPoint(x: position.x - base.x, y: position.y - base.y), at: index)
    }

    /// Changes the grid, keeping the correction already dialled in.
    mutating func setMeshDivisions(columns: Int, rows: Int) {
        mesh = mesh.resized(columns: columns, rows: rows)
    }

    /// Prepares the grid for a correction that needs somewhere to put curvature.
    ///
    /// A four-corner layer has no interior points, so bending it to a surface would
    /// silently do nothing — which looks exactly like the scan having failed. Raising
    /// it to a usable density first is safe: an unwarped mesh reproduces the
    /// homography exactly, so this moves nothing.
    mutating func prepareMeshForCorrection(columns: Int = 4, rows: Int = 4) {
        guard !mesh.isSubdivided else { return }
        setMeshDivisions(columns: columns, rows: rows)
    }

    /// The mapping as authored by hand, with any previous bend removed.
    ///
    /// This is what a new solve has to measure from. Solving against the already-bent
    /// positions and adding the result would apply the correction a second time, and
    /// tapping "bend" twice would double it.
    var handAuthored: LayerTransform {
        var copy = self
        copy.mesh.clearScanCorrection()
        return copy
    }

    /// Replaces the scan-derived part of the correction. Hand offsets are untouched.
    mutating func setScanCorrection(_ offsets: [CGPoint]) {
        mesh.setScanOffsets(offsets)
    }

    /// True when every cell touching `index` stays convex — a folded cell makes its
    /// homography degenerate and the patch turns inside out or disappears.
    func meshIsDrawable(movingPointAt index: Int, to position: CGPoint,
                        scale: Double = 1) -> Bool {
        guard (0..<mesh.pointCount).contains(index) else { return false }

        var probe = self
        probe.mesh.setOffset(.zero, at: index)
        let unoffset = probe.meshPoints(scale: scale)[index]
        probe.mesh.setOffset(CGPoint(x: position.x - unoffset.x,
                                     y: position.y - unoffset.y), at: index)

        let cells = probe.meshCells(scale: scale)
        let column = index % mesh.pointsAcross
        let row = index / mesh.pointsAcross

        // The point is shared by up to four cells; only those can have folded.
        for cellRow in (row - 1)...row where (0..<mesh.rows).contains(cellRow) {
            for cellColumn in (column - 1)...column where (0..<mesh.columns).contains(cellColumn) {
                let cellIndex = cellRow * mesh.columns + cellColumn
                guard cells.indices.contains(cellIndex) else { continue }
                if !cells[cellIndex].quad.isConvex { return false }
            }
        }
        return true
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

    /// Swaps what the layer shows, keeping everything about where it shows it.
    ///
    /// The mapping is the expensive part of a show and the content inside it is not,
    /// so this deliberately touches neither the transform, the correction grid, the
    /// blend nor the audio routing. Two small courtesies are worth the special case:
    /// a layer still carrying its old content's name is renamed to the new one, and a
    /// colour wash — which is tinted white at full mix so the swatch is visible — has
    /// that tint dropped, or real content would come out washed to flat white.
    func replacingContent(with content: LayerContent) -> MappingLayer {
        var copy = self
        if copy.name == copy.content.displayName {
            copy.name = content.displayName
        }
        let wasSolid = copy.content.isSolid
        copy.content = content
        if wasSolid, !content.isSolid {
            copy.appearance.tintAmount = 0
        }
        return copy
    }

    /// Creates a generator layer filling the whole canvas.
    ///
    /// Generators are backdrops far more often than they are objects, and unlike a
    /// clip they have no aspect ratio of their own to preserve, so covering the
    /// canvas is the useful default. Warp it down afterwards if you want a panel.
    static func make(generator kind: GeneratorKind) -> MappingLayer {
        var layer = MappingLayer(name: kind.displayName,
                                 content: .generator(kind, kind.defaultSettings))
        layer.transform.size = CGSize(width: 1, height: 1)
        return layer
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
