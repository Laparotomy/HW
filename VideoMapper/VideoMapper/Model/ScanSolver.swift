import CoreGraphics
import Foundation
import simd

/// Turns a scan into mesh offsets that bend a layer around the surface it was
/// scanned from.
///
/// ## What this actually corrects
///
/// A projector always sees its own image undistorted, whatever shape the surface is.
/// Distortion is something *other* viewpoints see: light that should have landed at
/// one place on a flat wall lands nearer or further on a curved one, and from the
/// side that shift reads as the image sliding across the object.
///
/// So the correction is defined against two things: a reference plane fitted to the
/// surface, and a viewpoint. The authored mapping — the quad and any hand-dragged
/// mesh points — describes where the content should sit *as if the surface were that
/// plane*. This solver moves each control point so that the light actually reaching
/// the real surface lines up, from the audience's position, with where it would have
/// landed on the plane.
///
/// On a flat surface the two coincide and every offset comes out zero, so applying a
/// scan to a flat wall is a no-op rather than a nudge. That property is what the
/// tests pin down first.
///
/// ## What it does not do
///
/// It is not a calibrated projector solution. The projector's pose is assumed to be
/// where the phone was held at capture, and its frustum comes from a throw ratio
/// typed in by hand. Both carry error, and that error shows up as a whole-image
/// shift or scale — which is exactly what the four corner handles are for. The
/// curvature, which is the part corner handles cannot express, is what this recovers.
enum ScanSolver {

    /// Why a scan could not be turned into a warp. Each of these is something the
    /// operator can act on, so none of them is reported as a generic failure.
    enum Failure: Equatable {
        case noDepth
        case audienceAtProjector
        case surfaceNotVisible
        case tooFewSamples

        var message: String {
            switch self {
            case .noDepth:
                return "This scan has no depth data, so there is no surface shape to follow. "
                    + "Depth needs an iPhone with a LiDAR scanner."
            case .audienceAtProjector:
                return "The audience is at the projector. From there the image is already "
                    + "correct — move the viewpoint to the side or back to see what needs bending."
            case .surfaceNotVisible:
                return "The layer does not land on any scanned surface. Re-scan with the "
                    + "phone aimed the way the projector is, or move the layer."
            case .tooFewSamples:
                return "Too little of the surface came back from the scan. Dark, glossy and "
                    + "distant surfaces measure badly; try again closer or with more light."
            }
        }
    }

    /// Newton needs very few steps here: the residual is nearly linear over the span
    /// of one cell, and each step costs one depth lookup.
    private static let iterations = 6
    /// Step used to estimate the Jacobian numerically, in canvas units.
    private static let derivativeStep = 0.004
    /// Give up on a point once it lands this far out; a runaway means the ray left
    /// the scanned region and the authored position is the better answer.
    private static let maximumOffset = 0.35

    /// Computes a mesh offset for every control point of `transform`'s grid.
    ///
    /// Returns offsets in normalized canvas units, ready to be written into
    /// `MeshWarp`. Points whose ray misses the scan keep a zero offset rather than
    /// being dropped, so the grid stays whole.
    static func meshOffsets(scan: SurfaceScan,
                            optics: ProjectorOptics,
                            audience: AudienceOffset,
                            transform: LayerTransform,
                            canvasAspect: Double) -> Result<[CGPoint], Failure> {
        guard let depth = scan.depth else { return .failure(.noDepth) }
        guard !audience.isAtProjector else { return .failure(.audienceAtProjector) }
        guard depth.coverage > 0.2 else { return .failure(.tooFewSamples) }

        let optics = optics.clamped()
        let mesh = transform.mesh
        let authored = transform.meshPoints()
        let eye = audience.projectorSpacePosition

        // The reference plane is fitted to the surface under the layer, not to the
        // whole scan: a layer on a column should be corrected against that column,
        // not against the room behind it.
        guard let plane = fitPlane(depth: depth, camera: scan.camera,
                                   optics: optics, canvasAspect: canvasAspect,
                                   authored: authored)
        else { return .failure(.surfaceNotVisible) }

        var offsets = [CGPoint](repeating: .zero, count: mesh.pointCount)
        var solved = 0

        for index in 0..<min(mesh.pointCount, authored.count) {
            let start = authored[index]
            guard let target = planeTarget(canvasPoint: start, plane: plane, eye: eye,
                                           optics: optics, canvasAspect: canvasAspect)
            else { continue }

            guard let corrected = solve(canvasPoint: start, target: target, eye: eye,
                                        depth: depth, camera: scan.camera,
                                        optics: optics, canvasAspect: canvasAspect)
            else { continue }

            let offset = CGPoint(x: corrected.x - start.x, y: corrected.y - start.y)
            guard abs(offset.x) <= maximumOffset, abs(offset.y) <= maximumOffset else { continue }
            offsets[index] = offset
            solved += 1
        }

        guard solved > 0 else { return .failure(.surfaceNotVisible) }
        return .success(offsets)
    }

    // MARK: - Geometry

    /// A plane, written as inverse axial depth being linear in the frame.
    ///
    /// For a pinhole camera, a plane makes 1/(axial depth) an exactly affine function
    /// of the *tangent* coordinates x/-z and y/-z. Fitting `a*x + b*y + c` to inverse
    /// axial depth is therefore a plane fit outright — no eigenvectors, no degenerate
    /// orientations, and a plain 3x3 least squares.
    ///
    /// The tangent coordinates matter: the same fit against the components of a unit
    /// ray is *not* linear, because the third component is a square root of the other
    /// two, and a flat wall would come back slightly curved at the edges of the frame.
    struct ReferencePlane: Equatable {
        var a: Double
        var b: Double
        var c: Double

        /// Depth along the view axis where a ray meets the plane.
        func axialDepth(along ray: SIMD3<Double>) -> Double? {
            guard ray.z < 0 else { return nil }
            let inverse = a * (ray.x / -ray.z) + b * (ray.y / -ray.z) + c
            guard inverse > 1e-9 else { return nil }
            return 1 / inverse
        }

        /// Distance travelled along a unit ray to reach the plane.
        func distance(along ray: SIMD3<Double>) -> Double? {
            guard ray.z < 0, let axial = axialDepth(along: ray) else { return nil }
            return axial / -ray.z
        }
    }

    /// Fits the reference plane to the surface visible under the authored points.
    static func fitPlane(depth: DepthGrid, camera: ScanCamera,
                         optics: ProjectorOptics, canvasAspect: Double,
                         authored: [CGPoint]) -> ReferencePlane? {
        // Normal equations for [a b c] against inverse depth.
        var ata = simd_double3x3(0)
        var atb = SIMD3<Double>(repeating: 0)
        var samples = 0

        for point in authored {
            let ray = optics.ray(toCanvas: point, canvasAspect: canvasAspect)
            guard ray.z < 0,
                  let axial = surfaceAxialDepth(along: ray, depth: depth, camera: camera),
                  axial > 0 else { continue }
            let row = SIMD3(ray.x / -ray.z, ray.y / -ray.z, 1)
            ata += outerProduct(row, row)
            atb += row * (1 / axial)
            samples += 1
        }

        // Three unknowns need three independent samples; below that the fit is a
        // guess dressed as a plane.
        guard samples >= 3 else { return nil }
        let determinant = ata.determinant
        guard abs(determinant) > 1e-12 else { return nil }
        let solution = ata.inverse * atb
        guard solution.x.isFinite, solution.y.isFinite, solution.z.isFinite else { return nil }
        return ReferencePlane(a: solution.x, b: solution.y, c: solution.z)
    }

    private static func outerProduct(_ u: SIMD3<Double>, _ v: SIMD3<Double>) -> simd_double3x3 {
        simd_double3x3(columns: (u * v.x, u * v.y, u * v.z))
    }

    /// Distance from the projector to the real surface along a ray, by looking the
    /// ray up in the scan's depth grid.
    ///
    /// The phone and the projector are assumed to share a position and an aim — that
    /// is what the capture step asks the operator to arrange — so a projector ray is
    /// also a phone-camera ray, and the phone's much wider frame is what makes the
    /// lookup possible at all.
    static func surfaceAxialDepth(along ray: SIMD3<Double>, depth: DepthGrid,
                                  camera: ScanCamera) -> Double? {
        guard ray.z < 0, let image = camera.project(cameraSpace: ray) else { return nil }
        return depth.depth(at: image)
    }

    static func surfaceDistance(along ray: SIMD3<Double>, depth: DepthGrid,
                                camera: ScanCamera) -> Double? {
        guard let axial = surfaceAxialDepth(along: ray, depth: depth, camera: camera)
        else { return nil }
        // The grid stores depth along the view axis; the ray is a unit vector, so
        // converting to distance along the ray is a single divide.
        let cosine = -ray.z
        guard cosine > 1e-6 else { return nil }
        return axial / cosine
    }

    /// Where the audience sees the authored point land on the reference plane.
    private static func planeTarget(canvasPoint: CGPoint, plane: ReferencePlane,
                                    eye: SIMD3<Double>, optics: ProjectorOptics,
                                    canvasAspect: Double) -> SIMD3<Double>? {
        let ray = optics.ray(toCanvas: canvasPoint, canvasAspect: canvasAspect)
        guard let distance = plane.distance(along: ray), distance > 0 else { return nil }
        return ray * distance
    }

    /// Newton's method on the two-dimensional residual: how far the lit point misses
    /// the audience's line of sight to the target.
    private static func solve(canvasPoint start: CGPoint, target: SIMD3<Double>,
                              eye: SIMD3<Double>, depth: DepthGrid, camera: ScanCamera,
                              optics: ProjectorOptics, canvasAspect: Double) -> CGPoint? {
        // A basis across the audience's line of sight, so the residual is measured
        // in the two directions that actually matter.
        let sight = target - eye
        let length = simd_length(sight)
        guard length > 1e-6 else { return nil }
        let forward = sight / length
        let (right, up) = basis(perpendicularTo: forward)

        func residual(_ point: CGPoint) -> SIMD2<Double>? {
            let ray = optics.ray(toCanvas: point, canvasAspect: canvasAspect)
            guard let distance = surfaceDistance(along: ray, depth: depth, camera: camera),
                  distance > 0 else { return nil }
            let lit = ray * distance
            let delta = lit - eye
            // Perpendicular miss distance, scaled to the target's range so the two
            // components are comparable regardless of how far away the surface is.
            let along = simd_dot(delta, forward)
            guard along > 1e-6 else { return nil }
            let scaled = delta * (length / along)
            let miss = scaled - sight
            return SIMD2(simd_dot(miss, right), simd_dot(miss, up))
        }

        guard var current = residual(start) else { return nil }
        var point = start

        for _ in 0..<iterations {
            if simd_length(current) < 1e-5 { break }

            let stepX = CGPoint(x: point.x + derivativeStep, y: point.y)
            let stepY = CGPoint(x: point.x, y: point.y + derivativeStep)
            guard let byX = residual(stepX), let byY = residual(stepY) else { break }

            let jacobian = simd_double2x2(columns: ((byX - current) / derivativeStep,
                                                   (byY - current) / derivativeStep))
            let determinant = jacobian.determinant
            // A flat Jacobian means the surface stops responding to the ray moving —
            // an edge, or a hole. The last good position is the honest answer.
            guard abs(determinant) > 1e-9 else { break }

            let step = jacobian.inverse * current
            let next = CGPoint(x: point.x - step.x, y: point.y - step.y)
            guard next.x.isFinite, next.y.isFinite,
                  let nextResidual = residual(next) else { break }

            // Only accept a step that actually improves things; a scan with a step
            // change in depth can otherwise send Newton off across the canvas.
            guard simd_length(nextResidual) < simd_length(current) else { break }
            point = next
            current = nextResidual
        }

        return point
    }

    /// Any two unit vectors perpendicular to `forward` and to each other.
    private static func basis(perpendicularTo forward: SIMD3<Double>)
        -> (SIMD3<Double>, SIMD3<Double>) {
        // Pick the world axis least aligned with `forward`, so the cross product is
        // never near zero.
        let seed: SIMD3<Double> = abs(forward.y) < 0.9 ? SIMD3(0, 1, 0) : SIMD3(1, 0, 0)
        let right = simd_normalize(simd_cross(seed, forward))
        let up = simd_cross(forward, right)
        return (right, up)
    }
}
