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

/// The hand-dragged correction and the scan-derived one are kept in separate arrays.
/// They answer to different owners: one is what the operator dragged and must never
/// be recomputed, the other is derived and must be replaced wholesale by each new
/// solve. Summing them into one array is what made bending twice double the bend.
final class MeshCorrectionSeparationTests: XCTestCase {

    func testAFreshMeshHasNeitherKindOfCorrection() {
        let mesh = MeshWarp(columns: 2, rows: 2)
        XCTAssertFalse(mesh.isWarped)
        XCTAssertFalse(mesh.hasScanCorrection)
        XCTAssertEqual(mesh.scanOffsets.count, mesh.pointCount)
    }

    func testTheDrawnOffsetIsTheSumOfBoth() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        mesh.setOffset(CGPoint(x: 0.1, y: 0), at: 4)
        var scan = [CGPoint](repeating: .zero, count: mesh.pointCount)
        scan[4] = CGPoint(x: 0, y: -0.05)
        mesh.setScanOffsets(scan)

        XCTAssertEqual(mesh.offset(at: 4), CGPoint(x: 0.1, y: 0))
        XCTAssertEqual(mesh.effectiveOffset(at: 4), CGPoint(x: 0.1, y: -0.05))
        XCTAssertTrue(mesh.isWarped)
        XCTAssertTrue(mesh.hasScanCorrection)
    }

    func testSettingTheScanCorrectionReplacesTheWholeField() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        mesh.setScanOffsets([CGPoint](repeating: CGPoint(x: 0.05, y: 0.05),
                                      count: mesh.pointCount))
        mesh.setScanOffsets([CGPoint](repeating: CGPoint(x: 0.01, y: 0),
                                      count: mesh.pointCount))
        XCTAssertTrue(mesh.scanOffsets.allSatisfy { $0 == CGPoint(x: 0.01, y: 0) })
    }

    func testAShortOrLongScanFieldIsSizedToTheGrid() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        mesh.setScanOffsets([CGPoint(x: 0.1, y: 0.1)])
        XCTAssertEqual(mesh.scanOffsets.count, 9)
        XCTAssertEqual(mesh.scanOffsets[8], .zero)

        mesh.setScanOffsets([CGPoint](repeating: CGPoint(x: 0.2, y: 0), count: 99))
        XCTAssertEqual(mesh.scanOffsets.count, 9)
    }

    func testClearingTheScanCorrectionKeepsTheHandOne() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        mesh.setOffset(CGPoint(x: 0.1, y: 0), at: 4)
        mesh.setScanOffsets([CGPoint](repeating: CGPoint(x: 0.03, y: 0), count: 9))

        mesh.clearScanCorrection()
        XCTAssertFalse(mesh.hasScanCorrection)
        XCTAssertTrue(mesh.isWarped)
        XCTAssertEqual(mesh.offset(at: 4), CGPoint(x: 0.1, y: 0))
    }

    func testResetClearsBoth() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        mesh.setOffset(CGPoint(x: 0.1, y: 0), at: 4)
        mesh.setScanOffsets([CGPoint](repeating: CGPoint(x: 0.03, y: 0), count: 9))
        mesh.reset()
        XCTAssertFalse(mesh.isWarped)
        XCTAssertFalse(mesh.hasScanCorrection)
    }

    /// Resizing has to carry both fields, or changing the grid density would silently
    /// throw away whichever one it forgot.
    func testResizingCarriesBothFields() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        mesh.setOffset(CGPoint(x: 0.1, y: -0.05), column: 1, row: 1)
        var scan = [CGPoint](repeating: .zero, count: mesh.pointCount)
        scan[mesh.index(column: 1, row: 1)] = CGPoint(x: -0.02, y: 0.04)
        mesh.setScanOffsets(scan)

        let bigger = mesh.resized(columns: 4, rows: 4)
        let centre = bigger.index(column: 2, row: 2)
        XCTAssertEqual(bigger.offset(at: centre).x, 0.1, accuracy: 1e-12)
        XCTAssertEqual(bigger.offset(at: centre).y, -0.05, accuracy: 1e-12)
        XCTAssertEqual(bigger.scanOffsets[centre].x, -0.02, accuracy: 1e-12)
        XCTAssertEqual(bigger.scanOffsets[centre].y, 0.04, accuracy: 1e-12)
    }

    /// Dragging a handle on a bent layer must put it under the finger, and must write
    /// only to the hand field.
    func testDraggingAHandleOnABentLayerMovesOnlyTheHandField() {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 2, rows: 2)
        var scan = [CGPoint](repeating: .zero, count: transform.mesh.pointCount)
        scan[4] = CGPoint(x: 0.03, y: -0.02)
        transform.setScanCorrection(scan)

        let target = CGPoint(x: 0.55, y: 0.47)
        transform.setMeshPoint(4, to: target)

        let landed = transform.meshPoints()[4]
        XCTAssertEqual(landed.x, target.x, accuracy: 1e-9)
        XCTAssertEqual(landed.y, target.y, accuracy: 1e-9)
        XCTAssertEqual(transform.mesh.scanOffsets[4], CGPoint(x: 0.03, y: -0.02))
    }

    func testHandAuthoredStripsOnlyTheBend() {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 2, rows: 2)
        transform.setMeshPoint(4, to: CGPoint(x: 0.55, y: 0.45))
        let handOnly = transform.meshPoints()

        var scan = [CGPoint](repeating: .zero, count: transform.mesh.pointCount)
        scan[4] = CGPoint(x: 0.03, y: -0.02)
        transform.setScanCorrection(scan)

        XCTAssertNotEqual(transform.meshPoints(), handOnly)
        XCTAssertEqual(transform.handAuthored.meshPoints(), handOnly)
    }

    func testBothFieldsRoundTripThroughCodable() throws {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 2, rows: 2)
        transform.setMeshPoint(4, to: CGPoint(x: 0.55, y: 0.45))
        transform.setScanCorrection(
            [CGPoint](repeating: CGPoint(x: 0.01, y: 0.02), count: transform.mesh.pointCount))

        let data = try JSONEncoder().encode(transform)
        let decoded = try JSONDecoder().decode(LayerTransform.self, from: data)
        XCTAssertEqual(decoded, transform)
        XCTAssertTrue(decoded.mesh.hasScanCorrection)
    }

    /// A mesh saved before the scan field existed still has to open.
    func testAMeshSavedWithoutAScanFieldStillDecodes() throws {
        let json = """
        {"columns": 2, "rows": 2,
         "offsets": [[0,0],[0,0],[0,0],[0,0],[0.1,0],[0,0],[0,0],[0,0],[0,0]]}
        """
        let mesh = try JSONDecoder().decode(MeshWarp.self, from: Data(json.utf8))
        XCTAssertEqual(mesh.scanOffsets.count, 9)
        XCTAssertFalse(mesh.hasScanCorrection)
        XCTAssertEqual(mesh.offset(at: 4).x, 0.1, accuracy: 1e-12)
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
        // CGPoint and CGSize encode as two-element arrays, not keyed objects —
        // this is the shape the app has always written.
        let json = """
        {
          "center": [0.5, 0.5],
          "size": [0.6, 0.6],
          "rotation": 0,
          "cornerOffsets": [[0, 0], [0.1, 0], [0, 0], [0, 0]]
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
        {"columns": 3, "rows": 3, "offsets": [[0.1, 0.1]]}
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

/// Adding a point one at a time, where the surface needs it.
///
/// The grid is stored as the positions of its dividing lines rather than as a count,
/// which is what lets the spacing be uneven: points crowded where a wall bends and
/// left sparse where it is flat. A tap inserts a line each way, so the new point
/// lands under the finger and brings its row and column with it.
final class MeshPointInsertionTests: XCTestCase {

    // MARK: - Lines

    func testInsertingAColumnAddsOnePointPerRow() {
        var mesh = MeshWarp()
        XCTAssertTrue(mesh.insertColumn(at: 0.3))
        XCTAssertEqual(mesh.columns, 2)
        XCTAssertEqual(mesh.rows, 1)
        XCTAssertEqual(mesh.pointCount, 6)
        XCTAssertEqual(mesh.columnPositions, [0, 0.3, 1])
        XCTAssertFalse(mesh.isEvenlySpaced)
    }

    func testInsertingARowAddsOnePointPerColumn() {
        var mesh = MeshWarp(columns: 3, rows: 1)
        XCTAssertTrue(mesh.insertRow(at: 0.8))
        XCTAssertEqual(mesh.rows, 2)
        XCTAssertEqual(mesh.pointCount, 12)
        XCTAssertEqual(mesh.rowPositions, [0, 0.8, 1])
    }

    /// Lines closer together than a fingertip cannot be told apart on the stage, and
    /// a cell that thin has nothing useful to warp.
    func testALineTooCloseToAnotherIsRefused() {
        var mesh = MeshWarp()
        XCTAssertTrue(mesh.insertColumn(at: 0.5))
        XCTAssertFalse(mesh.canInsertColumn(at: 0.52))
        XCTAssertFalse(mesh.insertColumn(at: 0.52))
        XCTAssertEqual(mesh.columns, 2)
        XCTAssertTrue(mesh.insertColumn(at: 0.6))
    }

    func testALineOnTopOfTheLayersOwnEdgeIsRefused() {
        var mesh = MeshWarp()
        XCTAssertFalse(mesh.insertColumn(at: 0.01))
        XCTAssertFalse(mesh.insertColumn(at: 0.999))
        XCTAssertFalse(mesh.insertRow(at: 0))
        XCTAssertEqual(mesh.pointCount, 4)
    }

    func testANonFiniteInsertionIsRefused() {
        var mesh = MeshWarp()
        XCTAssertFalse(mesh.insertColumn(at: .nan))
        XCTAssertFalse(mesh.insertRow(at: .infinity))
        XCTAssertEqual(mesh.pointCount, 4)
    }

    /// Every cell is its own draw call, so the grid has to stop somewhere.
    func testTheGridStopsAtItsCap() {
        var mesh = MeshWarp()
        // Evenly spread insertions, all far enough apart to be accepted until the
        // cap itself refuses them.
        for step in 1...20 {
            mesh.insertColumn(at: Double(step) / 21)
        }
        XCTAssertEqual(mesh.columns, MeshWarp.maximumDivisions)
        XCTAssertFalse(mesh.insertColumn(at: 0.5001))
    }

    // MARK: - What happens to the correction

    /// A point added to a mapping that has already been dialled in must not disturb
    /// the correction around it.
    func testInsertingKeepsTheNeighbouringOffsetsExactly() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        mesh.setOffset(CGPoint(x: 0.05, y: -0.03), column: 1, row: 1)

        XCTAssertTrue(mesh.insertColumn(at: 0.9))
        // The old centre is still the second column, now of four points across.
        XCTAssertEqual(mesh.offset(column: 1, row: 1), CGPoint(x: 0.05, y: -0.03))
        XCTAssertEqual(mesh.columnPositions, [0, 0.5, 0.9, 1])
    }

    /// The new point inherits the shape it is being inserted into, so the surface
    /// does not jump where the point appears.
    func testANewPointStartsOnTheSurfaceItSplits() {
        var mesh = MeshWarp(columns: 2, rows: 1)
        mesh.setOffset(CGPoint(x: 0.1, y: 0), column: 1, row: 0)
        mesh.setOffset(CGPoint(x: 0.1, y: 0), column: 1, row: 1)

        XCTAssertTrue(mesh.insertColumn(at: 0.25))
        // Half way between an offset of zero and one of 0.1.
        XCTAssertEqual(mesh.offset(column: 1, row: 0).x, 0.05, accuracy: 1e-12)
    }

    func testInsertingCarriesTheScanFieldToo() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        var scan = [CGPoint](repeating: .zero, count: mesh.pointCount)
        scan[mesh.index(column: 1, row: 1)] = CGPoint(x: 0, y: 0.04)
        mesh.setScanOffsets(scan)

        XCTAssertTrue(mesh.insertRow(at: 0.9))
        XCTAssertEqual(mesh.scanOffsets.count, mesh.pointCount)
        XCTAssertEqual(mesh.scanOffset(at: mesh.index(column: 1, row: 1)),
                       CGPoint(x: 0, y: 0.04))
    }

    // MARK: - Removing

    func testRemovingAnInteriorLineTakesItsPointsWithIt() {
        var mesh = MeshWarp(columns: 3, rows: 2)
        XCTAssertTrue(mesh.removeColumn(1))
        XCTAssertEqual(mesh.columns, 2)
        XCTAssertEqual(mesh.offsets.count, mesh.pointCount)
        XCTAssertEqual(mesh.scanOffsets.count, mesh.pointCount)
    }

    /// The outer lines are the layer's own sides. Removing one would not remove a
    /// correction point, it would delete an edge of the surface.
    func testTheEdgesCannotBeRemoved() {
        var mesh = MeshWarp(columns: 2, rows: 2)
        XCTAssertFalse(mesh.removeColumn(0))
        XCTAssertFalse(mesh.removeColumn(2))
        XCTAssertFalse(mesh.removeRow(0))
        XCTAssertFalse(mesh.removeRow(2))
        XCTAssertEqual(mesh.pointCount, 9)
    }

    func testRemovingKeepsTheSurvivingOffsets() {
        var mesh = MeshWarp(columns: 3, rows: 1)
        mesh.setOffset(CGPoint(x: 0.2, y: 0), column: 2, row: 0)
        XCTAssertTrue(mesh.removeColumn(1))
        // The point that was third across is now second, and still carries its offset.
        XCTAssertEqual(mesh.offset(column: 1, row: 0), CGPoint(x: 0.2, y: 0))
    }

    // MARK: - Through the layer

    func testATapPutsAPointUnderTheFinger() {
        var transform = LayerTransform()
        let target = CGPoint(x: 0.3, y: 0.7)
        XCTAssertTrue(transform.insertMeshPoint(near: target))

        let index = transform.mesh.index(column: 1, row: 1)
        let landed = transform.meshPoints()[index]
        XCTAssertEqual(landed.x, target.x, accuracy: 1e-5)
        XCTAssertEqual(landed.y, target.y, accuracy: 1e-5)
    }

    func testATapOutsideTheLayerAddsNothing() {
        var transform = LayerTransform()
        transform.size = CGSize(width: 0.4, height: 0.4)
        XCTAssertFalse(transform.insertMeshPoint(near: CGPoint(x: 0.95, y: 0.95)))
        XCTAssertEqual(transform.mesh.pointCount, 4)
    }

    /// The invariant the whole mesh design rests on, now for a point added by hand
    /// rather than by the density pickers.
    func testAddingAPointToAKeystonedMappingDoesNotMoveIt() {
        var transform = LayerTransform()
        transform.setCorner(1, to: CGPoint(x: 0.92, y: 0.18))
        transform.setCorner(2, to: CGPoint(x: 0.88, y: 0.83))
        let before = transform.quad()
        let cornersBefore = transform.meshPoints()

        // The quad's own projective centre, so the inserted lines land at (0.5, 0.5)
        // in the layer's parameters and both of them are certain to be accepted.
        let centre = Homography.apply(Homography.unitSquare(to: transform.quad()),
                                      to: CGPoint(x: 0.5, y: 0.5))
        XCTAssertTrue(transform.insertMeshPoint(near: centre))

        XCTAssertEqual(transform.quad(), before)
        let cells = transform.meshCells()
        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(cells.first!.quad[0].x, cornersBefore.first!.x, accuracy: 1e-5)
        XCTAssertEqual(cells.last!.quad[2].y, cornersBefore.last!.y, accuracy: 1e-5)
    }

    /// An uneven grid has to hand each cell exactly its own share of the texture, or
    /// the image is stretched on one side of the new line and squeezed on the other.
    func testAnUnevenGridSlicesTheTextureByItsOwnLines() {
        var transform = LayerTransform()
        XCTAssertTrue(transform.insertMeshPoint(near: CGPoint(x: 0.3, y: 0.7)))
        let cells = transform.meshCells()

        XCTAssertEqual(cells.count, 4)
        XCTAssertEqual(cells[0].uvOrigin, .zero)
        // The tap's position reaches the grid through a `simd_float3x3`, so the line
        // lands at single-precision accuracy rather than exactly on 0.3.
        XCTAssertEqual(cells[0].uvSize.width, 0.3, accuracy: 1e-5)
        XCTAssertEqual(cells[0].uvSize.height, 0.7, accuracy: 1e-5)
        XCTAssertEqual(cells[1].uvOrigin.x, 0.3, accuracy: 1e-5)
        XCTAssertEqual(cells[1].uvSize.width, 0.7, accuracy: 1e-5)

        let area = cells.reduce(0.0) { $0 + $1.uvSize.width * $1.uvSize.height }
        XCTAssertEqual(area, 1, accuracy: 1e-9)
    }

    func testRemovingAPointTakesItsRowAndColumn() {
        var transform = LayerTransform()
        XCTAssertTrue(transform.insertMeshPoint(near: CGPoint(x: 0.3, y: 0.7)))
        let index = transform.mesh.index(column: 1, row: 1)
        XCTAssertTrue(transform.removeMeshPoint(index))
        XCTAssertFalse(transform.mesh.isSubdivided)
        XCTAssertEqual(transform.mesh.pointCount, 4)
    }

    func testRemovingACornerIsRefused() {
        var transform = LayerTransform()
        XCTAssertTrue(transform.insertMeshPoint(near: CGPoint(x: 0.5, y: 0.5)))
        XCTAssertFalse(transform.removeMeshPoint(0))
        XCTAssertFalse(transform.removeMeshPoint(transform.mesh.pointCount - 1))
        XCTAssertTrue(transform.mesh.isSubdivided)
    }

    func testAnOutOfRangeRemovalIsSafe() {
        var transform = LayerTransform()
        XCTAssertFalse(transform.removeMeshPoint(99))
        XCTAssertFalse(transform.removeMeshPoint(-1))
    }

    // MARK: - Where a canvas point sits inside a layer

    func testMeshParameterIsTheInverseOfTheQuadsOwnMap() {
        var transform = LayerTransform()
        transform.setCorner(1, to: CGPoint(x: 0.9, y: 0.2))
        let parameter = CGPoint(x: 0.37, y: 0.62)
        let canvasPoint = Homography.apply(Homography.unitSquare(to: transform.quad()),
                                           to: parameter)

        let recovered = transform.meshParameter(at: canvasPoint)
        XCTAssertEqual(recovered?.x ?? -1, parameter.x, accuracy: 1e-5)
        XCTAssertEqual(recovered?.y ?? -1, parameter.y, accuracy: 1e-5)
    }

    func testAPointOutsideTheLayerHasNoParameter() {
        var transform = LayerTransform()
        transform.size = CGSize(width: 0.3, height: 0.3)
        XCTAssertNil(transform.meshParameter(at: CGPoint(x: 0.02, y: 0.02)))
    }

    // MARK: - Persistence

    func testAnUnevenGridRoundTrips() throws {
        var mesh = MeshWarp()
        XCTAssertTrue(mesh.insertColumn(at: 0.2))
        XCTAssertTrue(mesh.insertRow(at: 0.85))
        mesh.setOffset(CGPoint(x: 0.01, y: 0.02), column: 1, row: 1)

        let decoded = try JSONDecoder().decode(MeshWarp.self,
                                               from: JSONEncoder().encode(mesh))
        XCTAssertEqual(decoded, mesh)
        XCTAssertEqual(decoded.columnPositions, [0, 0.2, 1])
        XCTAssertEqual(decoded.rowPositions, [0, 0.85, 1])
    }

    /// The counts are written alongside the line positions so a build that predates
    /// uneven grids still opens the show — with even spacing, which is wrong in the
    /// spacing but is a show rather than a decoding failure.
    func testTheLegacyCountsAreWrittenToo() throws {
        var mesh = MeshWarp()
        XCTAssertTrue(mesh.insertColumn(at: 0.2))
        XCTAssertTrue(mesh.insertRow(at: 0.85))

        let object = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(mesh)) as? [String: Any])
        XCTAssertEqual(object["columns"] as? Int, 2)
        XCTAssertEqual(object["rows"] as? Int, 2)
        XCTAssertNotNil(object["columnPositions"])
    }

    func testAGridSavedAsCountsOnlyComesBackEven() throws {
        let json = """
        {"columns": 2, "rows": 3, "offsets": []}
        """
        let mesh = try JSONDecoder().decode(MeshWarp.self, from: Data(json.utf8))
        XCTAssertEqual(mesh.columns, 2)
        XCTAssertEqual(mesh.rows, 3)
        XCTAssertTrue(mesh.isEvenlySpaced)
        XCTAssertEqual(mesh.offsets.count, 12)
    }

    /// A hand-edited or corrupted file must not be able to produce a grid the
    /// renderer can index out of bounds.
    func testCorruptLinePositionsAreRepaired() throws {
        let json = """
        {"columnPositions": [0.9, 0.2, 0.2, -3, 42, 0.5],
         "rowPositions": [0.5], "offsets": []}
        """
        let mesh = try JSONDecoder().decode(MeshWarp.self, from: Data(json.utf8))
        XCTAssertEqual(mesh.columnPositions.first, 0)
        XCTAssertEqual(mesh.columnPositions.last, 1)
        XCTAssertEqual(mesh.columnPositions, mesh.columnPositions.sorted())
        XCTAssertEqual(mesh.offsets.count, mesh.pointCount)
        XCTAssertEqual(mesh.scanOffsets.count, mesh.pointCount)
    }
}
