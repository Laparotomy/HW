import CoreGraphics
import simd

/// A quadrilateral in normalized canvas space (0...1, origin top-left, y down).
///
/// Corner order matches the unit square used for texture sampling:
/// `p00` is (u:0, v:0), `p10` is (u:1, v:0), `p11` is (u:1, v:1), `p01` is (u:0, v:1).
struct Quad: Codable, Equatable {
    var p00: CGPoint
    var p10: CGPoint
    var p11: CGPoint
    var p01: CGPoint

    static let unit = Quad(p00: CGPoint(x: 0, y: 0),
                           p10: CGPoint(x: 1, y: 0),
                           p11: CGPoint(x: 1, y: 1),
                           p01: CGPoint(x: 0, y: 1))

    var corners: [CGPoint] {
        get { [p00, p10, p11, p01] }
        set {
            guard newValue.count == 4 else { return }
            p00 = newValue[0]; p10 = newValue[1]; p11 = newValue[2]; p01 = newValue[3]
        }
    }

    subscript(index: Int) -> CGPoint {
        get { corners[index] }
        set {
            switch index {
            case 0: p00 = newValue
            case 1: p10 = newValue
            case 2: p11 = newValue
            default: p01 = newValue
            }
        }
    }

    var center: CGPoint {
        CGPoint(x: (p00.x + p10.x + p11.x + p01.x) / 4,
                y: (p00.y + p10.y + p11.y + p01.y) / 4)
    }

    /// Point-in-quad test, done as two triangles. Used to pick a layer by tapping
    /// the stage, so it must agree with what the GPU actually draws.
    func contains(_ point: CGPoint) -> Bool {
        func sign(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (a.x - c.x) * (b.y - c.y) - (b.x - c.x) * (a.y - c.y)
        }
        func inTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> Bool {
            let d1 = sign(point, a, b), d2 = sign(point, b, c), d3 = sign(point, c, a)
            let hasNegative = d1 < 0 || d2 < 0 || d3 < 0
            let hasPositive = d1 > 0 || d2 > 0 || d3 > 0
            return !(hasNegative && hasPositive)
        }
        return inTriangle(p00, p10, p11) || inTriangle(p00, p11, p01)
    }

    /// True when the corners still form a convex, non self-intersecting shape.
    /// A degenerate quad has no valid homography, so the editor refuses drags that create one.
    var isConvex: Bool {
        let pts = corners
        var sign = 0
        for i in 0..<4 {
            let a = pts[i], b = pts[(i + 1) % 4], c = pts[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 1e-9 { return false }
            let s = cross > 0 ? 1 : -1
            if sign == 0 { sign = s } else if sign != s { return false }
        }
        return true
    }
}

/// Projective transform helpers.
///
/// Video mapping needs a *homography* rather than an affine transform: dragging one
/// corner of a projected quad has to foreshorten the whole image, which a 2x3 matrix
/// cannot express.
enum Homography {

    /// Matrix mapping the unit square onto `quad`, in column-major `simd` order.
    ///
    /// Uses Heckbert's closed-form solution for the square-to-quad case, which is exact
    /// and needs no iterative solver.
    static func unitSquare(to quad: Quad) -> simd_float3x3 {
        let x0 = Double(quad.p00.x), y0 = Double(quad.p00.y)
        let x1 = Double(quad.p10.x), y1 = Double(quad.p10.y)
        let x2 = Double(quad.p11.x), y2 = Double(quad.p11.y)
        let x3 = Double(quad.p01.x), y3 = Double(quad.p01.y)

        let sx = x0 - x1 + x2 - x3
        let sy = y0 - y1 + y2 - y3

        let a: Double, b: Double, c: Double, d: Double, e: Double, f: Double, g: Double, h: Double

        if abs(sx) < 1e-12 && abs(sy) < 1e-12 {
            // Parallelogram: the projective terms vanish and the map is affine.
            a = x1 - x0; b = x2 - x1; c = x0
            d = y1 - y0; e = y2 - y1; f = y0
            g = 0; h = 0
        } else {
            let dx1 = x1 - x2, dx2 = x3 - x2
            let dy1 = y1 - y2, dy2 = y3 - y2
            let den = dx1 * dy2 - dx2 * dy1
            guard abs(den) > 1e-12 else { return matrix_identity_float3x3 }
            g = (sx * dy2 - dx2 * sy) / den
            h = (dx1 * sy - sx * dy1) / den
            a = x1 - x0 + g * x1
            b = x3 - x0 + h * x3
            c = x0
            d = y1 - y0 + g * y1
            e = y3 - y0 + h * y3
            f = y0
        }

        // simd_float3x3 takes columns; the matrix acts on (u, v, 1).
        return simd_float3x3(columns: (SIMD3<Float>(Float(a), Float(d), Float(g)),
                                       SIMD3<Float>(Float(b), Float(e), Float(h)),
                                       SIMD3<Float>(Float(c), Float(f), 1)))
    }

    /// Applies a homography to a point, dividing through by the homogeneous coordinate.
    static func apply(_ m: simd_float3x3, to point: CGPoint) -> CGPoint {
        let v = m * SIMD3<Float>(Float(point.x), Float(point.y), 1)
        guard abs(v.z) > 1e-9 else { return .zero }
        return CGPoint(x: CGFloat(v.x / v.z), y: CGFloat(v.y / v.z))
    }
}

extension CGSize {
    /// Largest size with the given aspect ratio that fits inside the receiver.
    ///
    /// Used to letterbox the canvas identically on the phone's stage and on a
    /// projector, so what you edit is what the projector shows.
    func fitting(aspect: Double) -> CGSize {
        guard width > 0, height > 0, aspect > 0 else { return self }
        if width / height > aspect {
            return CGSize(width: height * aspect, height: height)
        }
        return CGSize(width: width, height: width / aspect)
    }
}

extension CGPoint {
    static func + (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x + r.x, y: l.y + r.y) }
    static func - (l: CGPoint, r: CGPoint) -> CGPoint { CGPoint(x: l.x - r.x, y: l.y - r.y) }
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }
}
