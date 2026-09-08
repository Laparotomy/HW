import XCTest
import simd
@testable import VideoMapper

final class HomographyTests: XCTestCase {

    private func map(_ m: simd_float3x3, _ u: Float, _ v: Float) -> CGPoint {
        Homography.apply(m, to: CGPoint(x: CGFloat(u), y: CGFloat(v)))
    }

    private func assertClose(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-4,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testUnitQuadIsIdentity() {
        let m = Homography.unitSquare(to: .unit)
        assertClose(map(m, 0, 0), CGPoint(x: 0, y: 0))
        assertClose(map(m, 1, 1), CGPoint(x: 1, y: 1))
        assertClose(map(m, 0.5, 0.25), CGPoint(x: 0.5, y: 0.25))
    }

    /// Every corner must land exactly on its pin, otherwise dragging a handle would
    /// not put the image where the finger is.
    func testCornersMapExactly() {
        let quad = Quad(p00: CGPoint(x: 0.25, y: 0.10),
                        p10: CGPoint(x: 0.75, y: 0.10),
                        p11: CGPoint(x: 0.95, y: 0.90),
                        p01: CGPoint(x: 0.05, y: 0.90))
        let m = Homography.unitSquare(to: quad)
        assertClose(map(m, 0, 0), quad.p00)
        assertClose(map(m, 1, 0), quad.p10)
        assertClose(map(m, 1, 1), quad.p11)
        assertClose(map(m, 0, 1), quad.p01)
    }

    /// A keystone must foreshorten: the centre of the image sits above the centroid
    /// of the quad. An affine transform would put it exactly at the centroid, so
    /// this is the test that proves the mapping is genuinely projective.
    func testKeystoneForeshortens() {
        let quad = Quad(p00: CGPoint(x: 0.25, y: 0.10),
                        p10: CGPoint(x: 0.75, y: 0.10),
                        p11: CGPoint(x: 0.95, y: 0.90),
                        p01: CGPoint(x: 0.05, y: 0.90))
        let centre = map(Homography.unitSquare(to: quad), 0.5, 0.5)
        XCTAssertEqual(centre.x, 0.5, accuracy: 1e-4)
        XCTAssertLessThan(centre.y, 0.48, "narrow top edge must pull the mid-point upward")
        XCTAssertGreaterThan(centre.y, 0.30)
    }

    /// A parallelogram takes the affine branch; it must still be exact.
    func testParallelogramUsesAffineBranch() {
        let quad = Quad(p00: CGPoint(x: 0.3, y: 0.2),
                        p10: CGPoint(x: 0.7, y: 0.35),
                        p11: CGPoint(x: 0.6, y: 0.75),
                        p01: CGPoint(x: 0.2, y: 0.6))
        let m = Homography.unitSquare(to: quad)
        assertClose(map(m, 1, 1), quad.p11)
        // No perspective term, so w stays 1 everywhere.
        let w = m.columns.0.z * 0.5 + m.columns.1.z * 0.5 + m.columns.2.z
        XCTAssertEqual(w, 1, accuracy: 1e-5)
    }

    func testDegenerateQuadFallsBackToIdentity() {
        let collapsed = Quad(p00: .zero, p10: .zero, p11: .zero, p01: .zero)
        let m = Homography.unitSquare(to: collapsed)
        // Not a crash and not NaN is the requirement here.
        XCTAssertFalse(m.columns.0.x.isNaN)
    }
}

final class QuadTests: XCTestCase {
    func testContainsPoint() {
        let quad = Quad(p00: CGPoint(x: 0.2, y: 0.2),
                        p10: CGPoint(x: 0.8, y: 0.2),
                        p11: CGPoint(x: 0.8, y: 0.8),
                        p01: CGPoint(x: 0.2, y: 0.8))
        XCTAssertTrue(quad.contains(CGPoint(x: 0.5, y: 0.5)))
        XCTAssertTrue(quad.contains(CGPoint(x: 0.21, y: 0.79)))
        XCTAssertFalse(quad.contains(CGPoint(x: 0.1, y: 0.5)))
        XCTAssertFalse(quad.contains(CGPoint(x: 0.5, y: 0.95)))
    }

    func testConvexity() {
        XCTAssertTrue(Quad.unit.isConvex)
        // Corner dragged past the opposite edge: a bow-tie.
        let folded = Quad(p00: CGPoint(x: 0, y: 0),
                          p10: CGPoint(x: 1, y: 0),
                          p11: CGPoint(x: 0, y: 1),
                          p01: CGPoint(x: 1, y: 1))
        XCTAssertFalse(folded.isConvex)
    }
}

final class LayerTransformTests: XCTestCase {

    func testDefaultQuadIsCentred() {
        var transform = LayerTransform()
        transform.center = CGPoint(x: 0.5, y: 0.5)
        transform.size = CGSize(width: 0.5, height: 0.5)
        let quad = transform.quad()
        XCTAssertEqual(quad.p00.x, 0.25, accuracy: 1e-6)
        XCTAssertEqual(quad.p11.y, 0.75, accuracy: 1e-6)
        XCTAssertEqual(quad.center.x, 0.5, accuracy: 1e-6)
    }

    func testScaleArgumentDoesNotMutateStoredSize() {
        var transform = LayerTransform()
        transform.size = CGSize(width: 0.5, height: 0.5)
        let scaled = transform.quad(scale: 2)
        XCTAssertEqual(scaled.p00.x, 0.0, accuracy: 1e-6)
        // Audio modulation must never write back into the project.
        XCTAssertEqual(transform.size.width, 0.5, accuracy: 1e-6)
    }

    /// Dragging a corner has to leave that corner exactly under the finger, and
    /// must not disturb the other three.
    func testSetCornerIsExactAndLocal() {
        var transform = LayerTransform()
        transform.size = CGSize(width: 0.5, height: 0.5)
        let before = transform.quad()
        let target = CGPoint(x: 0.1, y: 0.05)
        transform.setCorner(1, to: target)
        let after = transform.quad()
        XCTAssertEqual(after.p10.x, target.x, accuracy: 1e-6)
        XCTAssertEqual(after.p10.y, target.y, accuracy: 1e-6)
        XCTAssertEqual(after.p00, before.p00)
        XCTAssertEqual(after.p11, before.p11)
        XCTAssertTrue(transform.isWarped)

        transform.resetWarp()
        XCTAssertFalse(transform.isWarped)
        XCTAssertEqual(transform.quad().p10, before.p10)
    }

    /// Warp offsets are applied after rotation, so a rotated layer keeps its pins.
    func testSetCornerSurvivesRotation() {
        var transform = LayerTransform()
        transform.rotation = .pi / 6
        transform.size = CGSize(width: 0.4, height: 0.4)
        let target = CGPoint(x: 0.9, y: 0.15)
        transform.setCorner(2, to: target)
        XCTAssertEqual(transform.quad().p11.x, target.x, accuracy: 1e-6)
        XCTAssertEqual(transform.quad().p11.y, target.y, accuracy: 1e-6)
    }
}
