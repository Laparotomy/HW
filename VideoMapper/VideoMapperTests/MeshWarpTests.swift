import XCTest
@testable import VideoMapper

/// The mesh has one property that matters above all the others: adding points to a
/// finished mapping must not move the image. Alignment is the expensive part of a
/// show, and a subdivision that shifted it by even a pixel would make the feature
/// unusable on a surface someone had already lined up.
final class MeshWarpGeometryTests: XCTestCase {

    /// Loose by Double standards, tight by the standards of what is being checked:
    /// the homography is a `simd_float3x3`, so anything routed through it comes back
    /// with single-precision rounding — around 1e-7 on coordinates of order one.
    private func assertClose(_ a: CGPoint, _ b: CGPoint, accuracy: CGFloat = 1e-5,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, file: file, line: line)
    }

    func testAFreshMeshIsASingleCell() {
        let mesh = MeshWarp()
        XCTAssertEqual(mesh.columns, 1)
        XCTAssertEqual(mesh.rows, 1)
        XCTAssertEqual(mesh.pointCount, 4)
        XCTAssertEqual(mesh.cellCount, 1)
        XCTAssertFalse(mesh.isSubdivided)
        XCTAssertFalse(mesh.isWarped)
    }

    func testAnUnsubdividedLayerDrawsOneFullCell() {
        let transform = LayerTransform()
        let cells = transform.meshCells()
        XCTAssertEqual(cells.count, 1)
        XCTAssertEqual(cells[0].quad, transform.quad())
        XCTAssertEqual(cells[0].uvOrigin, .zero)
        XCTAssertEqual(cells[0].uvSize, CGSize(width: 1, height: 1))
    }

    /// The property the whole design rests on.
    func testSubdividingAKeystonedLayerDoesNotMoveIt() {
        var transform = LayerTransform()
        transform.setCorner(1, to: CGPoint(x: 0.9, y: 0.25))
        transform.setCorner(2, to: CGPoint(x: 0.85, y: 0.8))
        let before = transform.quad()

        transform.setMeshDivisions(columns: 4, rows: 3)
        let cells = transform.meshCells()

        XCTAssertEqual(cells.count, 12)
        // The outer corners of the cell grid still coincide with the layer's own quad.
        assertClose(cells.first!.quad[0], before[0])
        assertClose(cells.last!.quad[2], before[2])
        XCTAssertEqual(transform.quad(), before)
    }

    /// Interior points land on the quad's projective map, not on a bilinear blend of
    /// the corners. On a keystoned quad those differ, and only the former keeps the
    /// image continuous across cell boundaries.
    func testInteriorPointsFollowTheHomographyNotTheCorners() {
        var transform = LayerTransform()
        transform.setCorner(1, to: CGPoint(x: 0.95, y: 0.1))
        transform.setMeshDivisions(columns: 2, rows: 2)

        let points = transform.meshPoints()
        let centre = points[transform.mesh.index(column: 1, row: 1)]

        let quad = transform.quad()
        let bilinear = CGPoint(x: (quad[0].x + quad[1].x + quad[2].x + quad[3].x) / 4,
                               y: (quad[0].y + quad[1].y + quad[2].y + quad[3].y) / 4)
        let projective = Homography.apply(Homography.unitSquare(to: quad),
                                          to: CGPoint(x: 0.5, y: 0.5))

        assertClose(centre, projective)
        XCTAssertNotEqual(centre.y, bilinear.y)
    }

    func testCellsTileTheUVSpaceWithoutGaps() {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 4, rows: 2)
        let cells = transform.meshCells()

        XCTAssertEqual(cells.count, 8)
        let area = cells.reduce(0.0) { $0 + $1.uvSize.width * $1.uvSize.height }
        XCTAssertEqual(area, 1, accuracy: 1e-12)
        // Neighbouring cells share an edge exactly, or the image tears along it.
        XCTAssertEqual(cells[0].uvOrigin.x + cells[0].uvSize.width, cells[1].uvOrigin.x,
                       accuracy: 1e-12)
    }

    func testMovingAPointOffsetsOnlyThatPoint() {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 2, rows: 2)
        let before = transform.meshPoints()

        let index = transform.mesh.index(column: 1, row: 1)
        let target = CGPoint(x: 0.6, y: 0.4)
        transform.setMeshPoint(index, to: target)
        let after = transform.meshPoints()

        assertClose(after[index], target)
        for i in after.indices where i != index {
            assertClose(after[i], before[i])
        }
    }

    func testTheCentreOfAnUnwarpedGridIsTheCentreOfTheLayer() {
        var transform = LayerTransform()
        transform.size = CGSize(width: 1, height: 1)
        transform.setMeshDivisions(columns: 2, rows: 2)
        let points = transform.meshPoints()
        assertClose(points[transform.mesh.index(column: 1, row: 1)], CGPoint(x: 0.5, y: 0.5))
    }
}

final class MeshWarpEditingTests: XCTestCase {

    func testResizingKeepsTheCorrectionShape() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        mesh.setOffset(CGPoint(x: 0.1, y: -0.05), column: 1, row: 1)

        let bigger = mesh.resized(columns: 4, rows: 4)
        XCTAssertEqual(bigger.columns, 4)
        XCTAssertEqual(bigger.rows, 4)
        XCTAssertTrue(bigger.isWarped)
        // The old centre point maps onto the new grid's centre, unchanged.
        let centre = bigger.offset(column: 2, row: 2)
        XCTAssertEqual(centre.x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(centre.y, -0.05, accuracy: 1e-12)
    }

    func testResizingAnUnwarpedMeshJustChangesTheGrid() {
        let mesh = MeshWarp(columns: 1, rows: 1).resized(columns: 3, rows: 2)
        XCTAssertEqual(mesh.pointCount, 12)
        XCTAssertFalse(mesh.isWarped)
    }

    func testDivisionsAreClamped() {
        XCTAssertEqual(MeshWarp(columns: 0, rows: 0).columns, 1)
        XCTAssertEqual(MeshWarp(columns: 99, rows: 99).columns, MeshWarp.maximumDivisions)
        XCTAssertEqual(MeshWarp(columns: 99, rows: 99).rows, MeshWarp.maximumDivisions)
    }

    func testOffsetsAreSizedToTheGrid() {
        for columns in MeshWarp.availableDivisions {
            for rows in MeshWarp.availableDivisions {
                let mesh = MeshWarp(columns: columns, rows: rows)
                XCTAssertEqual(mesh.offsets.count, (columns + 1) * (rows + 1))
            }
        }
    }

    func testOutOfRangeAccessIsSafe() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        XCTAssertEqual(mesh.offset(column: 99, row: 99), .zero)
        mesh.setOffset(CGPoint(x: 1, y: 1), at: 999)
        XCTAssertFalse(mesh.isWarped)
    }

    func testResetClearsTheCorrectionButKeepsTheGrid() {
        var mesh = MeshWarp(columns: 3, rows: 3)
        mesh.setOffset(CGPoint(x: 0.2, y: 0.2), column: 1, row: 1)
        mesh.reset()
        XCTAssertFalse(mesh.isWarped)
        XCTAssertEqual(mesh.columns, 3)
        XCTAssertEqual(mesh.pointCount, 16)
    }

    func testResetWarpClearsCornersAndMeshTogether() {
        var transform = LayerTransform()
        transform.setCorner(0, to: CGPoint(x: 0.1, y: 0.1))
        transform.setMeshDivisions(columns: 2, rows: 2)
        transform.setMeshPoint(4, to: CGPoint(x: 0.3, y: 0.3))
        XCTAssertTrue(transform.isWarped)

        transform.resetWarp()
        XCTAssertFalse(transform.isWarped)
        // The grid itself survives: you asked for points, not for them to vanish.
        XCTAssertTrue(transform.mesh.isSubdivided)
    }

    /// A folded cell makes its homography degenerate, and the patch turns inside out
    /// or disappears. The drag has to be refused before it is applied.
    func testAFoldingDragIsRejected() {
        var transform = LayerTransform()
        transform.size = CGSize(width: 1, height: 1)
        transform.setMeshDivisions(columns: 2, rows: 2)

        let corner = transform.mesh.index(column: 0, row: 0)
        XCTAssertTrue(transform.meshIsDrawable(movingPointAt: corner,
                                               to: CGPoint(x: 0.1, y: 0.1)))
        // Dragging the top-left corner past the opposite side of its cell folds it.
        XCTAssertFalse(transform.meshIsDrawable(movingPointAt: corner,
                                                to: CGPoint(x: 0.9, y: 0.9)))
    }

    func testAnOutOfRangePointIsNeverDrawable() {
        let transform = LayerTransform()
        XCTAssertFalse(transform.meshIsDrawable(movingPointAt: 99, to: CGPoint(x: 0.5, y: 0.5)))
    }
}

final class MeshWarpPersistenceTests: XCTestCase {

    func testAMeshRoundTripsThroughCodable() throws {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 3, rows: 2)
        transform.setMeshPoint(4, to: CGPoint(x: 0.42, y: 0.31))

        var project = MappingProject(name: "Mesh")
        project.layers = [MappingLayer(name: "Wall")]
        project.layers[0].transform = transform

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MappingProject.self, from: data)
        XCTAssertEqual(decoded.layers, project.layers)
        XCTAssertEqual(decoded.layers[0].transform.mesh.columns, 3)
        XCTAssertTrue(decoded.layers[0].transform.mesh.isWarped)
    }

    /// A show saved before the mesh existed has no `mesh` key at all. The synthesised
    /// decoder would reject it outright, which would lose the user's work.
    func testALayerSavedBeforeTheMeshExistedStillDecodes() throws {
        let json = """
        {
          "center": {"x": 0.5, "y": 0.5},
          "size": {"width": 0.6, "height": 0.6},
          "rotation": 0,
          "cornerOffsets": [
            {"x": 0, "y": 0}, {"x": 0.1, "y": 0}, {"x": 0, "y": 0}, {"x": 0, "y": 0}
          ]
        }
        """
        let transform = try JSONDecoder().decode(LayerTransform.self, from: Data(json.utf8))
        XCTAssertEqual(transform.mesh.columns, 1)
        XCTAssertEqual(transform.mesh.rows, 1)
        XCTAssertFalse(transform.mesh.isWarped)
        XCTAssertEqual(transform.cornerOffsets[1].x, 0.1, accuracy: 1e-12)
    }

    /// A stored offset array that does not match the stored grid must not be able to
    /// index the renderer out of bounds.
    func testAMismatchedOffsetArrayIsRepaired() throws {
        let json = """
        {"columns": 3, "rows": 3, "offsets": [{"x": 0.1, "y": 0.1}]}
        """
        let mesh = try JSONDecoder().decode(MeshWarp.self, from: Data(json.utf8))
        XCTAssertEqual(mesh.offsets.count, 16)
        XCTAssertEqual(mesh.offsets[0].x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(mesh.offsets[15], .zero)
    }

    func testAnOversizedStoredGridIsClamped() throws {
        let json = """
        {"columns": 500, "rows": 500, "offsets": []}
        """
        let mesh = try JSONDecoder().decode(MeshWarp.self, from: Data(json.utf8))
        XCTAssertEqual(mesh.columns, MeshWarp.maximumDivisions)
        XCTAssertEqual(mesh.offsets.count, mesh.pointCount)
    }
}
