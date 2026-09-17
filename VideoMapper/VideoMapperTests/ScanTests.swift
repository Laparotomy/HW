import XCTest
import simd
@testable import VideoMapper

/// The scanner itself needs a camera and a room. The maths does not, and the maths
/// is where a mistake would be invisible on a wall until the show started — a warp
/// that is subtly wrong still looks like a warp. So the solver is fed synthetic
/// surfaces whose correct answer is known in advance.
final class ScanCameraTests: XCTestCase {

    /// Roughly an iPhone rear camera in its native landscape frame.
    private func camera() -> ScanCamera {
        ScanCamera(focalX: 1500, focalY: 1500, principalX: 960, principalY: 720,
                   imageWidth: 1920, imageHeight: 1440)
    }

    func testTheCentreOfTheImageLooksStraightAhead() {
        let projected = camera().project(cameraSpace: SIMD3(0, 0, -1))
        XCTAssertEqual(projected?.x ?? .nan, 0.5, accuracy: 1e-12)
        XCTAssertEqual(projected?.y ?? .nan, 0.5, accuracy: 1e-12)
    }

    /// Camera space is y-up and image space is y-down; getting this backwards flips
    /// every warp vertically, which is the kind of bug that survives a code review
    /// and dies on a wall.
    func testAPointAboveTheAxisLandsAboveTheCentre() {
        let above = camera().project(cameraSpace: SIMD3(0, 1, -2))
        XCTAssertNotNil(above)
        XCTAssertLessThan(above!.y, 0.5)
        XCTAssertEqual(above!.x, 0.5, accuracy: 1e-12)
    }

    func testAPointToTheRightLandsRightOfCentre() {
        let right = camera().project(cameraSpace: SIMD3(1, 0, -2))
        XCTAssertNotNil(right)
        XCTAssertGreaterThan(right!.x, 0.5)
    }

    func testPointsBehindTheCameraDoNotProject() {
        XCTAssertNil(camera().project(cameraSpace: SIMD3(0, 0, 1)))
        XCTAssertNil(camera().project(cameraSpace: SIMD3(0, 0, 0)))
    }

    func testProjectAndUnprojectAreInverses() {
        let camera = camera()
        for point in [CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.1, y: 0.8),
                      CGPoint(x: 0.95, y: 0.05), CGPoint(x: 0, y: 1)] {
            let world = camera.unproject(point, depth: 3.5)
            XCTAssertEqual(world.z, -3.5, accuracy: 1e-9)
            let back = camera.project(cameraSpace: world)
            XCTAssertEqual(back?.x ?? .nan, point.x, accuracy: 1e-9)
            XCTAssertEqual(back?.y ?? .nan, point.y, accuracy: 1e-9)
        }
    }

    func testRaysAreUnitLengthAndPointForward() {
        let ray = camera().ray(through: CGPoint(x: 0.2, y: 0.7))
        XCTAssertEqual(simd_length(ray), 1, accuracy: 1e-9)
        XCTAssertLessThan(ray.z, 0)
    }
}

final class DepthGridTests: XCTestCase {

    private func flatGrid(_ value: Double, columns: Int = 9, rows: Int = 9) -> DepthGrid {
        DepthGrid(columns: columns, rows: rows,
                  depths: Array(repeating: value, count: columns * rows))
    }

    func testAShortArrayIsPaddedRatherThanTrusted() {
        let grid = DepthGrid(columns: 4, rows: 4, depths: [1, 2, 3])
        XCTAssertEqual(grid.depths.count, 16)
        XCTAssertEqual(grid.depth(column: 0, row: 0), 1)
        XCTAssertEqual(grid.depth(column: 3, row: 3), 0)
    }

    func testCoverageCountsOnlyRealReadings() {
        var depths = Array(repeating: 2.0, count: 16)
        depths[0] = 0
        depths[1] = 0
        let grid = DepthGrid(columns: 4, rows: 4, depths: depths)
        XCTAssertEqual(grid.coverage, 14.0 / 16.0, accuracy: 1e-12)
        XCTAssertEqual(flatGrid(2).coverage, 1, accuracy: 1e-12)
    }

    func testSamplingAFlatGridGivesTheSameDepthEverywhere() {
        let grid = flatGrid(2.5)
        for point in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5),
                      CGPoint(x: 1, y: 1), CGPoint(x: 0.33, y: 0.87)] {
            XCTAssertEqual(grid.depth(at: point) ?? .nan, 2.5, accuracy: 1e-12)
        }
    }

    func testSamplingInterpolatesBetweenReadings() {
        // A ramp from 1 at the left edge to 3 at the right.
        var depths: [Double] = []
        for _ in 0..<3 {
            depths += [1, 2, 3]
        }
        let grid = DepthGrid(columns: 3, rows: 3, depths: depths)
        XCTAssertEqual(grid.depth(at: CGPoint(x: 0.25, y: 0.5)) ?? .nan, 1.5, accuracy: 1e-12)
        XCTAssertEqual(grid.depth(at: CGPoint(x: 0.75, y: 0.5)) ?? .nan, 2.5, accuracy: 1e-12)
    }

    /// A hole must propagate rather than be smoothed over: interpolating against a
    /// missing reading invents a surface, and an invented surface bends the warp the
    /// wrong way with no sign that anything went wrong.
    func testAMissingReadingPoisonsItsNeighbourhood() {
        // 5 x 5 rather than 3 x 3: on the smaller grid the centre sample is a corner
        // of every cell, so a hole there refuses the whole image — correctly, but it
        // leaves nowhere to check that the refusal is local.
        var depths = Array(repeating: 2.0, count: 25)
        depths[12] = 0
        let grid = DepthGrid(columns: 5, rows: 5, depths: depths)
        XCTAssertNil(grid.depth(at: CGPoint(x: 0.5, y: 0.5)))
        // A corner well away from the hole still reads.
        XCTAssertEqual(grid.depth(at: CGPoint(x: 1, y: 0)) ?? .nan, 2, accuracy: 1e-12)
        XCTAssertEqual(grid.depth(at: CGPoint(x: 0, y: 1)) ?? .nan, 2, accuracy: 1e-12)
    }

    func testSamplingOutsideTheImageReturnsNothing() {
        let grid = flatGrid(2)
        XCTAssertNil(grid.depth(at: CGPoint(x: -0.01, y: 0.5)))
        XCTAssertNil(grid.depth(at: CGPoint(x: 0.5, y: 1.01)))
    }

    func testGridsRoundTripThroughCodable() throws {
        let grid = flatGrid(1.75, columns: 5, rows: 4)
        let data = try JSONEncoder().encode(grid)
        XCTAssertEqual(try JSONDecoder().decode(DepthGrid.self, from: data), grid)
    }

    /// A stored grid whose array does not match its own dimensions must not be able
    /// to index the sampler out of bounds.
    func testAMismatchedStoredGridIsRepaired() throws {
        let json = """
        {"columns": 4, "rows": 4, "depths": [1, 2]}
        """
        let grid = try JSONDecoder().decode(DepthGrid.self, from: Data(json.utf8))
        XCTAssertEqual(grid.depths.count, 16)
    }
}

final class ProjectorOpticsTests: XCTestCase {

    func testTheCentreOfTheCanvasIsTheLensAxisWithNoOffset() {
        var optics = ProjectorOptics()
        optics.verticalLensOffset = 0
        let ray = optics.ray(toCanvas: CGPoint(x: 0.5, y: 0.5), canvasAspect: 16.0 / 9.0)
        XCTAssertEqual(ray.x, 0, accuracy: 1e-12)
        XCTAssertEqual(ray.y, 0, accuracy: 1e-12)
        XCTAssertEqual(ray.z, -1, accuracy: 1e-12)
    }

    /// The throw ratio is the whole frustum: at `throwRatio` widths away the image is
    /// one width across, so the half-angle follows from it directly.
    func testTheThrowRatioSetsTheWidthOfTheImage() {
        var optics = ProjectorOptics()
        optics.throwRatio = 2
        optics.verticalLensOffset = 0
        let right = optics.ray(toCanvas: CGPoint(x: 1, y: 0.5), canvasAspect: 16.0 / 9.0)
        // At distance 2 the image half-width is 0.5, so the edge ray rises 0.25 per
        // unit of depth.
        XCTAssertEqual(right.x / -right.z, 0.25, accuracy: 1e-9)
    }

    func testATighterThrowRatioGivesANarrowerImage() {
        var wide = ProjectorOptics(); wide.throwRatio = 1; wide.verticalLensOffset = 0
        var tight = ProjectorOptics(); tight.throwRatio = 3; tight.verticalLensOffset = 0
        let wideEdge = wide.ray(toCanvas: CGPoint(x: 1, y: 0.5), canvasAspect: 1.5)
        let tightEdge = tight.ray(toCanvas: CGPoint(x: 1, y: 0.5), canvasAspect: 1.5)
        XCTAssertGreaterThan(wideEdge.x / -wideEdge.z, tightEdge.x / -tightEdge.z)
    }

    func testTheTopOfTheCanvasIsAboveTheBottom() {
        var optics = ProjectorOptics()
        optics.verticalLensOffset = 0
        let top = optics.ray(toCanvas: CGPoint(x: 0.5, y: 0), canvasAspect: 16.0 / 9.0)
        let bottom = optics.ray(toCanvas: CGPoint(x: 0.5, y: 1), canvasAspect: 16.0 / 9.0)
        XCTAssertGreaterThan(top.y, bottom.y)
    }

    func testLensOffsetLiftsTheWholeImage() {
        var level = ProjectorOptics(); level.verticalLensOffset = 0
        var raised = ProjectorOptics(); raised.verticalLensOffset = 0.5
        let a = level.ray(toCanvas: CGPoint(x: 0.5, y: 0.5), canvasAspect: 16.0 / 9.0)
        let b = raised.ray(toCanvas: CGPoint(x: 0.5, y: 0.5), canvasAspect: 16.0 / 9.0)
        XCTAssertGreaterThan(b.y, a.y)
    }

    func testClampingKeepsTheFrustumSane() {
        var optics = ProjectorOptics()
        optics.throwRatio = 0
        optics.verticalLensOffset = 99
        let clamped = optics.clamped()
        XCTAssertEqual(clamped.throwRatio, ProjectorOptics.throwRatioRange.lowerBound)
        XCTAssertEqual(clamped.verticalLensOffset, ProjectorOptics.lensOffsetRange.upperBound)
    }
}

final class ScanSolverTests: XCTestCase {

    private let camera = ScanCamera(focalX: 1500, focalY: 1500,
                                    principalX: 960, principalY: 720,
                                    imageWidth: 1920, imageHeight: 1440)

    private func optics() -> ProjectorOptics {
        ProjectorOptics(throwRatio: 1.5, verticalLensOffset: 0)
    }

    /// A wall square-on to the projector: every ray meets it at the same axial depth,
    /// which is exactly what ARKit's depth map stores.
    private func flatWall(at depth: Double) -> DepthGrid {
        DepthGrid(columns: 33, rows: 33,
                  depths: Array(repeating: depth, count: 33 * 33))
    }

    /// A surface that bulges toward the projector in the middle, like a column.
    private func bulgingWall(base: Double, bulge: Double) -> DepthGrid {
        let columns = 33, rows = 33
        var depths = [Double](repeating: 0, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let u = Double(column) / Double(columns - 1) - 0.5
                let v = Double(row) / Double(rows - 1) - 0.5
                let radius = min(1, sqrt(u * u + v * v) * 2)
                depths[row * columns + column] = base - bulge * cos(radius * .pi / 2)
            }
        }
        return DepthGrid(columns: columns, rows: rows, depths: depths)
    }

    private func scan(_ depth: DepthGrid?) -> SurfaceScan {
        SurfaceScan(name: "Test", imageFilename: "test.jpg", camera: camera, depth: depth)
    }

    private func transform() -> LayerTransform {
        var transform = LayerTransform()
        transform.size = CGSize(width: 0.6, height: 0.6)
        transform.setMeshDivisions(columns: 4, rows: 4)
        return transform
    }

    private func audience() -> AudienceOffset {
        AudienceOffset(right: 2, up: 0, back: 1)
    }

    // MARK: - Refusals

    func testAPhotoOnlyScanIsRefusedWithAReason() {
        let result = ScanSolver.meshOffsets(scan: scan(nil), optics: optics(),
                                            audience: audience(), transform: transform(),
                                            canvasAspect: 16.0 / 9.0)
        XCTAssertEqual(result, .failure(.noDepth))
    }

    /// From the projector's own position the image is correct whatever the surface
    /// does, so there is nothing to solve and saying so beats returning zeros.
    func testAnAudienceAtTheProjectorIsRefused() {
        let result = ScanSolver.meshOffsets(scan: scan(flatWall(at: 3)), optics: optics(),
                                            audience: AudienceOffset(right: 0, up: 0, back: 0),
                                            transform: transform(),
                                            canvasAspect: 16.0 / 9.0)
        XCTAssertEqual(result, .failure(.audienceAtProjector))
    }

    func testAMostlyEmptyScanIsRefused() {
        var depths = Array(repeating: 0.0, count: 33 * 33)
        for index in 0..<100 { depths[index] = 3 }
        let sparse = DepthGrid(columns: 33, rows: 33, depths: depths)
        let result = ScanSolver.meshOffsets(scan: scan(sparse), optics: optics(),
                                            audience: audience(), transform: transform(),
                                            canvasAspect: 16.0 / 9.0)
        XCTAssertEqual(result, .failure(.tooFewSamples))
    }

    // MARK: - The property that matters

    /// A flat wall *is* its own reference plane, so there is nothing to correct and
    /// every offset must come back zero. If this ever fails, applying a scan to an
    /// ordinary wall would nudge a finished mapping out of alignment.
    func testAFlatWallProducesNoCorrection() throws {
        let result = ScanSolver.meshOffsets(scan: scan(flatWall(at: 3)), optics: optics(),
                                            audience: audience(), transform: transform(),
                                            canvasAspect: 16.0 / 9.0)
        let offsets = try XCTUnwrap(try? result.get())
        XCTAssertEqual(offsets.count, 25)
        for offset in offsets {
            XCTAssertEqual(offset.x, 0, accuracy: 2e-3)
            XCTAssertEqual(offset.y, 0, accuracy: 2e-3)
        }
    }

    func testAFlatWallAtAnyDistanceStillProducesNoCorrection() throws {
        for distance in [1.5, 3.0, 6.0] {
            let result = ScanSolver.meshOffsets(scan: scan(flatWall(at: distance)),
                                                optics: optics(), audience: audience(),
                                                transform: transform(),
                                                canvasAspect: 16.0 / 9.0)
            let offsets = try XCTUnwrap(try? result.get())
            for offset in offsets {
                XCTAssertEqual(offset.x, 0, accuracy: 3e-3, "at \(distance) m")
                XCTAssertEqual(offset.y, 0, accuracy: 3e-3, "at \(distance) m")
            }
        }
    }

    // MARK: - Curvature

    func testACurvedSurfaceProducesACorrection() throws {
        let result = ScanSolver.meshOffsets(scan: scan(bulgingWall(base: 3, bulge: 0.5)),
                                            optics: optics(), audience: audience(),
                                            transform: transform(),
                                            canvasAspect: 16.0 / 9.0)
        let offsets = try XCTUnwrap(try? result.get())
        let largest = offsets.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
        XCTAssertGreaterThan(largest, 1e-3)
    }

    /// The audience is to the right, so a surface bulging toward the projector shifts
    /// the correction along that axis. A bulge with the viewer level and to the side
    /// should move points horizontally far more than vertically.
    func testTheCorrectionFollowsTheAudienceDirection() throws {
        let result = ScanSolver.meshOffsets(scan: scan(bulgingWall(base: 3, bulge: 0.6)),
                                            optics: optics(),
                                            audience: AudienceOffset(right: 3, up: 0, back: 0.5),
                                            transform: transform(),
                                            canvasAspect: 16.0 / 9.0)
        let offsets = try XCTUnwrap(try? result.get())
        let horizontal = offsets.map { abs($0.x) }.max() ?? 0
        let vertical = offsets.map { abs($0.y) }.max() ?? 0
        XCTAssertGreaterThan(horizontal, vertical)
    }

    /// Moving the audience further off-axis asks the surface to be bent further.
    func testAFurtherAudienceNeedsAStrongerCorrection() throws {
        func largestOffset(right: Double) throws -> Double {
            let result = ScanSolver.meshOffsets(
                scan: scan(bulgingWall(base: 3, bulge: 0.5)), optics: optics(),
                audience: AudienceOffset(right: right, up: 0, back: 0.5),
                transform: transform(), canvasAspect: 16.0 / 9.0)
            let offsets = try XCTUnwrap(try? result.get())
            return offsets.map { max(abs($0.x), abs($0.y)) }.max() ?? 0
        }
        XCTAssertGreaterThan(try largestOffset(right: 4), try largestOffset(right: 1))
    }

    func testOffsetsAreReturnedForEveryControlPoint() throws {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 6, rows: 3)
        let result = ScanSolver.meshOffsets(scan: scan(bulgingWall(base: 3, bulge: 0.4)),
                                            optics: optics(), audience: audience(),
                                            transform: transform,
                                            canvasAspect: 16.0 / 9.0)
        let offsets = try XCTUnwrap(try? result.get())
        XCTAssertEqual(offsets.count, 7 * 4)
    }

    // MARK: - Plane fit

    func testThePlaneFitRecoversAFlatWall() throws {
        let depth = flatWall(at: 4)
        let optics = optics()
        let authored = transform().meshPoints()
        let plane = try XCTUnwrap(ScanSolver.fitPlane(depth: depth, camera: camera,
                                                      optics: optics,
                                                      canvasAspect: 16.0 / 9.0,
                                                      authored: authored))
        for point in authored {
            let ray = optics.ray(toCanvas: point, canvasAspect: 16.0 / 9.0)
            let fitted = try XCTUnwrap(plane.distance(along: ray))
            let measured = try XCTUnwrap(ScanSolver.surfaceDistance(along: ray, depth: depth,
                                                                    camera: camera))
            XCTAssertEqual(fitted, measured, accuracy: 1e-6)
        }
    }

    /// Depth along the view axis is not depth along a slanted ray; conflating them
    /// would make a flat wall look curved at the edges of the frame.
    func testSlantedRaysTravelFurtherThanTheAxialDepth() throws {
        let depth = flatWall(at: 3)
        let optics = optics()
        let centre = optics.ray(toCanvas: CGPoint(x: 0.5, y: 0.5), canvasAspect: 16.0 / 9.0)
        let edge = optics.ray(toCanvas: CGPoint(x: 1, y: 0.5), canvasAspect: 16.0 / 9.0)
        let atCentre = try XCTUnwrap(ScanSolver.surfaceDistance(along: centre, depth: depth,
                                                                camera: camera))
        let atEdge = try XCTUnwrap(ScanSolver.surfaceDistance(along: edge, depth: depth,
                                                              camera: camera))
        XCTAssertEqual(atCentre, 3, accuracy: 1e-9)
        XCTAssertGreaterThan(atEdge, atCentre)
    }
}

final class ScanPersistenceTests: XCTestCase {

    func testAScanRoundTripsInsideAProject() throws {
        let camera = ScanCamera(focalX: 1500, focalY: 1500, principalX: 960,
                                principalY: 720, imageWidth: 1920, imageHeight: 1440)
        let grid = DepthGrid(columns: 4, rows: 4, depths: Array(repeating: 2.0, count: 16))
        var project = MappingProject(name: "Scanned")
        let scan = SurfaceScan(name: "Wall", imageFilename: "wall.jpg",
                               camera: camera, depth: grid)
        project.scans = [scan]
        project.activeScanID = scan.id
        project.optics.throwRatio = 1.2
        project.audience.right = 1.5

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MappingProject.self, from: data)

        XCTAssertEqual(decoded.scans, project.scans)
        XCTAssertEqual(decoded.activeScanID, scan.id)
        XCTAssertEqual(decoded.optics.throwRatio, 1.2)
        XCTAssertEqual(decoded.audience.right, 1.5)
        XCTAssertEqual(decoded.activeScan?.name, "Wall")
    }

    /// Scans, optics and the audience are all new keys. A show saved before any of
    /// them existed still has to open.
    func testAProjectSavedBeforeScansExistedStillDecodes() throws {
        let json = """
        {
          "id": "6B1E7E7A-0000-4000-8000-000000000001",
          "name": "Old Show",
          "canvasSize": [1920, 1080],
          "layers": [],
          "audio": {"clockSource": "freeRun", "volume": 1, "loops": true,
                    "manualBPM": 120, "latencyOffset": 0},
          "background": {"red": 0, "green": 0, "blue": 0, "alpha": 1},
          "createdAt": 700000000,
          "modifiedAt": 700000000
        }
        """
        let project = try JSONDecoder().decode(MappingProject.self, from: Data(json.utf8))
        XCTAssertEqual(project.name, "Old Show")
        XCTAssertTrue(project.scans.isEmpty)
        XCTAssertNil(project.activeScanID)
        XCTAssertEqual(project.optics, ProjectorOptics())
        XCTAssertEqual(project.audience, AudienceOffset())
        XCTAssertEqual(project.canvasSize, CGSize(width: 1920, height: 1080))
    }

    func testAReferencePhotoCountsAsReferencedMedia() {
        let camera = ScanCamera(focalX: 1, focalY: 1, principalX: 0, principalY: 0,
                                imageWidth: 2, imageHeight: 2)
        var project = MappingProject(name: "Scanned")
        project.scans = [SurfaceScan(name: "Wall", imageFilename: "wall.jpg",
                                     camera: camera, depth: nil)]
        XCTAssertTrue(project.referencedMedia.contains("wall.jpg"))
    }
}

final class CanvasPresetTests: XCTestCase {

    func testEveryPresetButCustomHasASize() {
        for preset in CanvasPreset.allCases where preset != .custom {
            XCTAssertNotNil(preset.size, preset.rawValue)
        }
        XCTAssertNil(CanvasPreset.custom.size)
    }

    func testAKnownSizeMatchesItsPreset() {
        XCTAssertEqual(CanvasPreset.matching(CGSize(width: 1920, height: 1080)), .hd)
        XCTAssertEqual(CanvasPreset.matching(CGSize(width: 1080, height: 1920)), .portraitHD)
        XCTAssertEqual(CanvasPreset.matching(CGSize(width: 1234, height: 567)), .custom)
    }

    func testValidationRejectsUnusableSizes() {
        XCTAssertNil(CanvasPreset.validate(width: 0, height: 100))
        XCTAssertNil(CanvasPreset.validate(width: 100, height: 0))
        XCTAssertNil(CanvasPreset.validate(width: -10, height: 100))
        XCTAssertNil(CanvasPreset.validate(width: 1e9, height: 100))
        XCTAssertNil(CanvasPreset.validate(width: .nan, height: 100))
    }

    func testValidationRoundsAcceptableSizes() {
        XCTAssertEqual(CanvasPreset.validate(width: 1920.4, height: 1080.6),
                       CGSize(width: 1920, height: 1081))
    }

    func testTheAspectRatioFollowsTheCanvas() {
        var project = MappingProject(name: "Portrait")
        project.canvasSize = CGSize(width: 1080, height: 1920)
        XCTAssertEqual(project.canvasAspect, 1080.0 / 1920.0, accuracy: 1e-12)
    }
}
