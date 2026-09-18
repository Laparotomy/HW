import CoreGraphics
import Foundation
import simd

/// A pinhole camera, stored so a scan can be reasoned about long after the AR
/// session that produced it has gone.
///
/// Convention, fixed here so the maths in this file and the tests agree: camera
/// space is right-handed with +X right, +Y up and the camera looking down -Z, which
/// is what ARKit uses. Image coordinates are normalized 0...1 with the origin at the
/// top left, which is what the rest of the app uses.
struct ScanCamera: Codable, Equatable {
    /// Focal lengths in pixels.
    var focalX: Double
    var focalY: Double
    /// Principal point in pixels.
    var principalX: Double
    var principalY: Double
    /// Resolution the intrinsics were measured at.
    var imageWidth: Double
    var imageHeight: Double

    var aspect: Double { imageHeight > 0 ? imageWidth / imageHeight : 1 }

    /// Normalized image coordinate of a point in camera space, or nil if it is
    /// behind the camera.
    func project(cameraSpace point: SIMD3<Double>) -> CGPoint? {
        guard point.z < 0, imageWidth > 0, imageHeight > 0 else { return nil }
        let pixelX = focalX * (point.x / -point.z) + principalX
        // point.z is negative in front, so dividing by it performs the y flip that
        // takes a y-up camera to a y-down image.
        let pixelY = focalY * (point.y / point.z) + principalY
        return CGPoint(x: pixelX / imageWidth, y: pixelY / imageHeight)
    }

    /// The camera-space point at `depth` metres along the ray through a normalized
    /// image coordinate. `depth` is distance along the view axis, which is what
    /// ARKit's depth map stores.
    func unproject(_ image: CGPoint, depth: Double) -> SIMD3<Double> {
        let pixelX = image.x * imageWidth
        let pixelY = image.y * imageHeight
        let x = (pixelX - principalX) / focalX * depth
        let y = (pixelY - principalY) / focalY * -depth
        return SIMD3(x, y, -depth)
    }

    /// Unit direction in camera space through a normalized image coordinate.
    func ray(through image: CGPoint) -> SIMD3<Double> {
        simd_normalize(unproject(image, depth: 1))
    }
}

/// Distance to the surface, sampled on a regular grid over the camera image.
///
/// A raw ARKit mesh is tens of thousands of triangles and belongs in neither a
/// project file nor this maths. A depth grid is what the warp actually needs, it is
/// a few thousand floats, and it is trivially testable — a synthetic grid stands in
/// for a real scan exactly.
struct DepthGrid: Codable, Equatable {
    /// Samples across and down. Both at least 2.
    private(set) var columns: Int
    private(set) var rows: Int
    /// Depth in metres, row-major. Zero means the scanner returned nothing there.
    private(set) var depths: [Double]

    init(columns: Int, rows: Int, depths: [Double]) {
        self.columns = max(2, columns)
        self.rows = max(2, rows)
        let needed = self.columns * self.rows
        self.depths = depths.count == needed
            ? depths
            : Array(depths.prefix(needed)) + Array(repeating: 0,
                                                   count: max(0, needed - depths.count))
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedColumns = try container.decode(Int.self, forKey: .columns)
        let storedRows = try container.decode(Int.self, forKey: .rows)
        let storedDepths = try container.decode([Double].self, forKey: .depths)
        self.init(columns: storedColumns, rows: storedRows, depths: storedDepths)
    }

    var sampleCount: Int { columns * rows }

    /// Fraction of samples that carry a reading. A scan of a dark or glossy surface
    /// comes back mostly empty, and that is worth telling the user rather than
    /// silently producing a flat warp.
    var coverage: Double {
        guard sampleCount > 0 else { return 0 }
        return Double(depths.filter { $0 > 0 }.count) / Double(sampleCount)
    }

    func depth(column: Int, row: Int) -> Double {
        guard column >= 0, column < columns, row >= 0, row < rows else { return 0 }
        return depths[row * columns + column]
    }

    /// Bilinear sample at a normalized image coordinate. Returns nil when any of the
    /// four surrounding samples is missing — interpolating against a hole invents
    /// geometry, and inventing geometry is how a warp ends up bent the wrong way.
    func depth(at image: CGPoint) -> Double? {
        guard image.x >= 0, image.x <= 1, image.y >= 0, image.y <= 1 else { return nil }
        let x = image.x * Double(columns - 1)
        let y = image.y * Double(rows - 1)
        let column = min(Int(x), columns - 2)
        let row = min(Int(y), rows - 2)
        let fx = x - Double(column)
        let fy = y - Double(row)

        let d00 = depth(column: column, row: row)
        let d10 = depth(column: column + 1, row: row)
        let d01 = depth(column: column, row: row + 1)
        let d11 = depth(column: column + 1, row: row + 1)
        guard d00 > 0, d10 > 0, d01 > 0, d11 > 0 else { return nil }

        let top = d00 + (d10 - d00) * fx
        let bottom = d01 + (d11 - d01) * fx
        return top + (bottom - top) * fy
    }

    /// Normalized image coordinate of a sample.
    func imagePoint(column: Int, row: Int) -> CGPoint {
        CGPoint(x: Double(column) / Double(columns - 1),
                y: Double(row) / Double(rows - 1))
    }

    private enum CodingKeys: String, CodingKey { case columns, rows, depths }
}

/// How the projector throws its image, as printed on the projector rather than
/// measured — which is the only form of this number anyone actually has.
struct ProjectorOptics: Codable, Equatable {
    /// Throw ratio: distance to the surface divided by image width. Every projector
    /// lists it; 1.5 is typical for a living-room machine.
    var throwRatio: Double = 1.5
    /// How far the image centre sits above the lens axis, as a fraction of image
    /// height. Most projectors standing on a table throw upward, so this is positive.
    var verticalLensOffset: Double = 0.5

    static let throwRatioRange: ClosedRange<Double> = 0.3...4
    static let lensOffsetRange: ClosedRange<Double> = -1.5...1.5

    func clamped() -> ProjectorOptics {
        ProjectorOptics(
            throwRatio: throwRatio.clamped(to: Self.throwRatioRange),
            verticalLensOffset: verticalLensOffset.clamped(to: Self.lensOffsetRange))
    }

    /// Direction, in the projector's own frame, of the ray that lights up a point on
    /// the canvas. Canvas coordinates run 0...1 with the origin top-left.
    func ray(toCanvas point: CGPoint, canvasAspect: Double) -> SIMD3<Double> {
        // Half-width of the image at unit distance follows straight from the throw
        // ratio: the image is one width across at `throwRatio` widths away.
        let halfWidth = 1 / (2 * max(throwRatio, 0.01))
        let halfHeight = halfWidth / max(canvasAspect, 0.01)
        let x = (point.x - 0.5) * 2 * halfWidth
        let y = (0.5 - point.y) * 2 * halfHeight + verticalLensOffset * 2 * halfHeight
        return simd_normalize(SIMD3(x, y, -1))
    }
}

/// Where the audience is, relative to the projector, in metres.
///
/// Only the position matters. Correcting a projection for a viewpoint means making
/// the lit points of the surface line up along the rays *from that viewpoint*, and
/// which way the viewer's head is turned, or how wide their field of view is, does
/// not change which ray a point lies on.
struct AudienceOffset: Codable, Equatable {
    /// Positive is to the projector's right.
    var right: Double = 0
    /// Positive is above the projector.
    var up: Double = 0
    /// Positive is behind the projector, away from the surface.
    var back: Double = 2

    static let range: ClosedRange<Double> = -10...10

    var isAtProjector: Bool {
        abs(right) < 1e-6 && abs(up) < 1e-6 && abs(back) < 1e-6
    }

    /// Position in the projector's own frame: +X right, +Y up, -Z toward the surface.
    var projectorSpacePosition: SIMD3<Double> {
        SIMD3(right.clamped(to: Self.range),
              up.clamped(to: Self.range),
              back.clamped(to: Self.range))
    }
}

/// A captured look at the surface: what it looked like, and how far away it was.
struct SurfaceScan: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var capturedAt: Date = Date()
    /// Reference photo inside the project's Media folder. Shown under the stage.
    var imageFilename: String
    var camera: ScanCamera
    /// Depth samples. Absent on a device with no LiDAR, where the scan is a
    /// reference photo and nothing more.
    var depth: DepthGrid?
    /// What the device could actually measure, recorded so the UI never claims more
    /// than was captured.
    var hasDepth: Bool { depth != nil }
}
