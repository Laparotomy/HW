import XCTest
@testable import VideoMapper

/// The unit tests each check one piece. These check the seams between pieces, which
/// is where the bugs that survive a green suite actually live: a warp that renders
/// from the wrong cells, a content swap that quietly loses an alignment, a scan
/// applied twice that doubles its own correction.
///
/// Everything here runs against the model rather than `ShowController`, because the
/// controller owns an audio session, a Metal device and a peer link, and a test that
/// starts all three to check a struct assignment is a test that will eventually fail
/// for reasons that have nothing to do with the code under test.

// MARK: - Content swapping

final class ContentSwapIntegrationTests: XCTestCase {

    private func mappedLayer() -> MappingLayer {
        var layer = MappingLayer(name: "Left pillar")
        layer.transform.setCorner(1, to: CGPoint(x: 0.88, y: 0.2))
        layer.transform.setMeshDivisions(columns: 3, rows: 3)
        layer.transform.setMeshPoint(5, to: CGPoint(x: 0.42, y: 0.31))
        layer.appearance.blendMode = .screen
        layer.appearance.feather = 0.2
        layer.modulation = [ModulationRoute(source: .bass, target: .intensity, amount: 0.7)]
        return layer
    }

    /// The whole promise of in-place content: aligning a surface is slow work and
    /// swapping what plays inside it must not cost any of it.
    func testSwappingContentKeepsTheEntireMapping() {
        let before = mappedLayer()
        let ref = MediaReference(kind: .video, filename: "clip.mov", displayName: "Clip",
                                 pixelSize: CGSize(width: 1920, height: 1080), duration: 8)
        let after = before.replacingContent(with: .video(ref, VideoPlayback()))

        XCTAssertEqual(after.transform, before.transform)
        XCTAssertEqual(after.appearance.blendMode, before.appearance.blendMode)
        XCTAssertEqual(after.appearance.feather, before.appearance.feather)
        XCTAssertEqual(after.modulation, before.modulation)
        XCTAssertEqual(after.id, before.id)
        XCTAssertTrue(after.content.isVideo)
    }

    func testSwappingContentSurvivesEveryContentKind() {
        let base = mappedLayer()
        let ref = MediaReference(kind: .image, filename: "a.png", displayName: "A",
                                 pixelSize: CGSize(width: 100, height: 100))
        let kinds: [LayerContent] = [
            .image(ref),
            .video(ref, VideoPlayback()),
            .generator(.cells, GeneratorKind.cells.defaultSettings),
            .solid
        ]
        for content in kinds {
            XCTAssertEqual(base.replacingContent(with: content).transform, base.transform)
        }
    }

    /// A colour wash is tinted white at full mix so its swatch is visible. Leaving
    /// that tint on when real content arrives would wash the content to flat white.
    func testFillingAColourLayerDropsItsTint() {
        var layer = MappingLayer(name: "Colour")
        XCTAssertEqual(layer.appearance.tintAmount, 1)

        layer = layer.replacingContent(with: .generator(.plasma,
                                                        GeneratorKind.plasma.defaultSettings))
        XCTAssertEqual(layer.appearance.tintAmount, 0)
    }

    /// A tint the operator chose on a media layer is theirs, not a leftover to clear.
    func testSwappingBetweenMediaKindsLeavesTheTintAlone() {
        let ref = MediaReference(kind: .image, filename: "a.png", displayName: "A",
                                 pixelSize: CGSize(width: 10, height: 10))
        var layer = MappingLayer(name: "Tinted", content: .image(ref))
        layer.appearance.tintAmount = 0.6

        let after = layer.replacingContent(with: .generator(.rings,
                                                            GeneratorKind.rings.defaultSettings))
        XCTAssertEqual(after.appearance.tintAmount, 0.6)
    }

    func testAnUnrenamedLayerFollowsItsContent() {
        let layer = MappingLayer(name: "Colour")
        let renamed = layer.replacingContent(with: .generator(.tunnel,
                                                              GeneratorKind.tunnel.defaultSettings))
        XCTAssertEqual(renamed.name, "Tunnel")
    }

    func testANameTheOperatorChoseIsKept() {
        let layer = MappingLayer(name: "Left pillar")
        let renamed = layer.replacingContent(with: .generator(.tunnel,
                                                              GeneratorKind.tunnel.defaultSettings))
        XCTAssertEqual(renamed.name, "Left pillar")
    }
}

// MARK: - Mesh through the render path

final class MeshRenderIntegrationTests: XCTestCase {

    private func engine() -> ModulationEngine { ModulationEngine() }

    /// The renderer draws `ResolvedLayer.cells`, not the layer's quad. If modulation
    /// stopped populating them the stage would simply go blank.
    func testResolvingALayerProducesDrawableCells() {
        var layer = MappingLayer(name: "Wall")
        layer.transform.setMeshDivisions(columns: 4, rows: 3)

        let offsets = engine().offsets(for: layer, features: AudioFeatures(),
                                       showTime: 0, fallbackBPM: 120)
        let resolved = engine().resolve(layer: layer, offsets: offsets)

        XCTAssertEqual(resolved.cells.count, 12)
        XCTAssertEqual(resolved.id, layer.id)
    }

    func testAnUnsubdividedLayerStillResolvesToExactlyOneCell() {
        let layer = MappingLayer(name: "Wall")
        let engine = engine()
        let resolved = engine.resolve(layer: layer,
                                      offsets: engine.offsets(for: layer,
                                                              features: AudioFeatures(),
                                                              showTime: 0, fallbackBPM: 120))
        XCTAssertEqual(resolved.cells.count, 1)
        XCTAssertEqual(resolved.cells[0].quad, resolved.quad)
    }

    /// Audio-driven scaling has to reach the cells, not just the outline, or a
    /// reactive layer would pulse its handles while the image stayed put.
    func testAudioScalingMovesTheCellsAndNotOnlyTheQuad() {
        var layer = MappingLayer(name: "Wall")
        layer.transform.setMeshDivisions(columns: 2, rows: 2)

        var offsets = ModulationOffsets()
        offsets.scale = 0.5
        let scaled = engine().resolve(layer: layer, offsets: offsets)
        let unscaled = engine().resolve(layer: layer, offsets: ModulationOffsets())

        XCTAssertNotEqual(scaled.cells[0].quad, unscaled.cells[0].quad)
        // The uv slices are a property of the grid, not of how big it is drawn.
        XCTAssertEqual(scaled.cells[0].uvOrigin, unscaled.cells[0].uvOrigin)
        XCTAssertEqual(scaled.cells[0].uvSize, unscaled.cells[0].uvSize)
    }

    /// Together the cells must cover the layer's own texture exactly once, or the
    /// image tears along a seam or repeats a strip.
    func testCellsTileTheLayerExactlyOnce() {
        for (columns, rows) in [(1, 1), (2, 3), (4, 4), (8, 8)] {
            var transform = LayerTransform()
            transform.setMeshDivisions(columns: columns, rows: rows)
            let cells = transform.meshCells()

            XCTAssertEqual(cells.count, columns * rows)
            let area = cells.reduce(0.0) { $0 + $1.uvSize.width * $1.uvSize.height }
            XCTAssertEqual(area, 1, accuracy: 1e-12, "\(columns)x\(rows)")

            let origins = Set(cells.map { "\($0.uvOrigin.x),\($0.uvOrigin.y)" })
            XCTAssertEqual(origins.count, cells.count, "\(columns)x\(rows) has a repeat")
        }
    }

    /// A generator is drawn through the same cells as a clip, so a subdivided
    /// generator layer must still come out whole.
    func testAGeneratorLayerSubdividesLikeAnyOther() {
        var layer = MappingLayer.make(generator: .kaleidoscope)
        layer.transform.setMeshDivisions(columns: 3, rows: 3)
        let engine = engine()
        let resolved = engine.resolve(layer: layer,
                                      offsets: engine.offsets(for: layer,
                                                              features: AudioFeatures(),
                                                              showTime: 0, fallbackBPM: 120))
        XCTAssertEqual(resolved.cells.count, 9)
        XCTAssertEqual(resolved.content.generator?.kind, .kaleidoscope)
    }
}

// MARK: - Scanning end to end

final class ScanApplicationIntegrationTests: XCTestCase {

    private let camera = ScanCamera(focalX: 1500, focalY: 1500, principalX: 960,
                                    principalY: 720, imageWidth: 1920, imageHeight: 1440)

    private func flatWall(at depth: Double) -> DepthGrid {
        DepthGrid(columns: 33, rows: 33, depths: Array(repeating: depth, count: 33 * 33))
    }

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

    private func scan(_ depth: DepthGrid) -> SurfaceScan {
        SurfaceScan(name: "Wall", imageFilename: "wall.jpg", camera: camera, depth: depth)
    }

    /// Mirrors what `ShowController.applyScan` does, in the model terms the
    /// controller now delegates to.
    private func apply(_ scan: SurfaceScan, to layer: inout MappingLayer,
                       optics: ProjectorOptics = ProjectorOptics(throwRatio: 1.5,
                                                                 verticalLensOffset: 0),
                       audience: AudienceOffset = AudienceOffset(right: 2, up: 0, back: 1),
                       canvasAspect: Double = 16.0 / 9.0) -> ScanSolver.Failure? {
        var transform = layer.transform
        transform.prepareMeshForCorrection()
        switch ScanSolver.meshOffsets(scan: scan, optics: optics, audience: audience,
                                      transform: transform.handAuthored,
                                      canvasAspect: canvasAspect) {
        case .failure(let failure):
            return failure
        case .success(let offsets):
            transform.setScanCorrection(offsets)
            layer.transform = transform
            return nil
        }
    }

    /// A four-corner layer has nowhere to put curvature, so bending it has to raise
    /// the grid first — silently doing nothing would look exactly like a failed scan.
    func testBendingAPlainQuadGivesItAGridToBendWith() {
        var layer = MappingLayer(name: "Column")
        XCTAssertFalse(layer.transform.mesh.isSubdivided)

        XCTAssertNil(apply(scan(bulgingWall(base: 3, bulge: 0.5)), to: &layer))
        XCTAssertTrue(layer.transform.mesh.isSubdivided)
        XCTAssertTrue(layer.transform.mesh.isWarped)
    }

    /// The property the whole feature rests on, checked here through the same path
    /// the app uses rather than against the solver directly.
    func testBendingToAFlatWallLeavesAFinishedMappingAlone() {
        var layer = MappingLayer(name: "Wall")
        layer.transform.setCorner(1, to: CGPoint(x: 0.85, y: 0.22))
        let quadBefore = layer.transform.quad()

        XCTAssertNil(apply(scan(flatWall(at: 3)), to: &layer))

        XCTAssertEqual(layer.transform.quad(), quadBefore)
        for offset in layer.transform.mesh.effectiveOffsets {
            XCTAssertEqual(offset.x, 0, accuracy: 3e-3)
            XCTAssertEqual(offset.y, 0, accuracy: 3e-3)
        }
    }

    /// Hand alignment is never touched by a bend: it lives in its own array.
    func testBendingLeavesHandAlignmentExactlyWhereItWas() {
        var layer = MappingLayer(name: "Column")
        layer.transform.setMeshDivisions(columns: 4, rows: 4)
        let index = layer.transform.mesh.index(column: 2, row: 2)
        layer.transform.setMeshPoint(index, to: CGPoint(x: 0.56, y: 0.44))
        let handOffset = layer.transform.mesh.offset(at: index)
        XCTAssertNotEqual(handOffset, .zero)

        XCTAssertNil(apply(scan(bulgingWall(base: 3, bulge: 0.5)), to: &layer))

        XCTAssertEqual(layer.transform.mesh.offset(at: index), handOffset)
        XCTAssertTrue(layer.transform.mesh.hasScanCorrection)
    }

    /// Tapping "bend" twice must give what tapping it once gives. Accumulating the
    /// correction instead of replacing it doubled the bend — this is the test that
    /// found that, and the one that keeps it fixed.
    func testBendingTwiceGivesExactlyWhatBendingOnceGives() {
        let surface = scan(bulgingWall(base: 3, bulge: 0.5))
        var once = MappingLayer(name: "Column")
        XCTAssertNil(apply(surface, to: &once))

        var twice = once
        XCTAssertNil(apply(surface, to: &twice))

        XCTAssertTrue(once.transform.mesh.hasScanCorrection)
        XCTAssertEqual(twice.transform.mesh.scanOffsets, once.transform.mesh.scanOffsets)
        XCTAssertEqual(twice.transform.meshPoints(), once.transform.meshPoints())
    }

    /// Bending is reversible without losing the hand work underneath it.
    func testRemovingABendLeavesTheHandAlignmentBehind() {
        var layer = MappingLayer(name: "Column")
        layer.transform.setMeshDivisions(columns: 4, rows: 4)
        let index = layer.transform.mesh.index(column: 1, row: 2)
        layer.transform.setMeshPoint(index, to: CGPoint(x: 0.4, y: 0.52))
        let handAuthored = layer.transform.meshPoints()

        XCTAssertNil(apply(scan(bulgingWall(base: 3, bulge: 0.5)), to: &layer))
        XCTAssertNotEqual(layer.transform.meshPoints(), handAuthored)

        layer.transform.mesh.clearScanCorrection()
        XCTAssertEqual(layer.transform.meshPoints(), handAuthored)
        XCTAssertTrue(layer.transform.mesh.isWarped)
    }

    func testAPhotoOnlyScanReportsWhyItCannotBend() {
        var layer = MappingLayer(name: "Column")
        let photoOnly = SurfaceScan(name: "Wall", imageFilename: "wall.jpg",
                                    camera: camera, depth: nil)
        XCTAssertEqual(apply(photoOnly, to: &layer), .noDepth)
        XCTAssertFalse(layer.transform.mesh.isWarped)
    }

    func testABendAlwaysLeavesTheGridDrawable() throws {
        var layer = MappingLayer(name: "Column")
        XCTAssertNil(apply(scan(bulgingWall(base: 2.5, bulge: 0.7)), to: &layer))

        // Every cell must stay convex, or its homography is degenerate and the patch
        // turns inside out on the wall.
        for cell in layer.transform.meshCells() {
            XCTAssertTrue(cell.quad.isConvex)
        }
    }

    func testABentLayerSurvivesBeingSavedAndReopened() throws {
        var layer = MappingLayer(name: "Column")
        XCTAssertNil(apply(scan(bulgingWall(base: 3, bulge: 0.5)), to: &layer))

        var project = MappingProject(name: "Bent")
        project.layers = [layer]
        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MappingProject.self, from: data)

        XCTAssertEqual(decoded.layers, project.layers)
        XCTAssertTrue(decoded.layers[0].transform.mesh.isWarped)
    }
}

// MARK: - Canvas

final class CanvasIntegrationTests: XCTestCase {

    /// Layer positions are normalized, so changing the projector's frame has to keep
    /// the mapping and change only the frame around it.
    func testChangingTheCanvasKeepsEveryLayerWhereItWas() {
        var project = MappingProject(name: "Show")
        var layer = MappingLayer(name: "Wall")
        layer.transform.setCorner(2, to: CGPoint(x: 0.8, y: 0.75))
        layer.transform.setMeshDivisions(columns: 2, rows: 2)
        project.layers = [layer]
        let before = project.layers[0].transform

        project.canvasSize = CGSize(width: 1080, height: 1920)

        XCTAssertEqual(project.layers[0].transform, before)
        XCTAssertEqual(project.canvasAspect, 1080.0 / 1920.0, accuracy: 1e-12)
    }

    /// A media layer is sized to fit the canvas it is dropped into, so the same clip
    /// lands differently in a portrait frame than a landscape one — and in both cases
    /// without being stretched.
    func testMediaIsFittedToWhicheverCanvasItLandsIn() {
        let ref = MediaReference(kind: .video, filename: "clip.mov", displayName: "Clip",
                                 pixelSize: CGSize(width: 1920, height: 1080), duration: 4)
        let landscape = MappingLayer.make(from: ref, canvasAspect: 16.0 / 9.0)
        let portrait = MappingLayer.make(from: ref, canvasAspect: 9.0 / 16.0)

        // Matching the canvas exactly means filling the chosen fraction of both axes.
        XCTAssertEqual(landscape.transform.size.width, 0.7, accuracy: 1e-9)
        XCTAssertEqual(landscape.transform.size.height, 0.7, accuracy: 1e-9)
        // In portrait the same clip has to shrink vertically to keep its shape.
        XCTAssertEqual(portrait.transform.size.width, 0.7, accuracy: 1e-9)
        XCTAssertLessThan(portrait.transform.size.height, 0.7)
    }

    func testAZeroSidedCanvasFallsBackRatherThanDividingByZero() {
        var project = MappingProject(name: "Broken")
        project.canvasSize = CGSize(width: 1920, height: 0)
        XCTAssertEqual(project.canvasAspect, 16.0 / 9.0, accuracy: 1e-12)
        XCTAssertTrue(project.canvasAspect.isFinite)
    }
}

// MARK: - A whole show

final class WholeProjectIntegrationTests: XCTestCase {

    /// One project using every feature added to this branch, through a save and a
    /// reload — which is also the path a follower device's copy takes.
    func testAShowUsingEverythingRoundTrips() throws {
        let clip = MediaReference(kind: .video, filename: "clip.mov", displayName: "Clip",
                                  pixelSize: CGSize(width: 1920, height: 1080), duration: 30)
        let camera = ScanCamera(focalX: 1500, focalY: 1500, principalX: 960,
                                principalY: 720, imageWidth: 1920, imageHeight: 1440)

        var project = MappingProject(name: "Everything")
        project.canvasSize = CGSize(width: 1920, height: 1200)
        project.audio.tempoMode = .manual
        project.audio.manualBPM = 128
        project.optics = ProjectorOptics(throwRatio: 0.8, verticalLensOffset: 1.1)
        project.audience = AudienceOffset(right: -1.5, up: 0.5, back: 4)
        project.scans = [SurfaceScan(name: "Stage wall", imageFilename: "wall.jpg",
                                     camera: camera,
                                     depth: DepthGrid(columns: 5, rows: 5,
                                                      depths: Array(repeating: 3.0, count: 25)))]
        project.activeScanID = project.scans[0].id

        var generator = MappingLayer.make(generator: .aurora)
        generator.transform.setMeshDivisions(columns: 3, rows: 2)
        generator.transform.setMeshPoint(4, to: CGPoint(x: 0.4, y: 0.3))

        var playback = VideoPlayback()
        playback.rate = 0
        var video = MappingLayer(name: "Frozen clip", content: .video(clip, playback))
        video.appearance.blendMode = .add
        video.modulation = [ModulationRoute(source: .treble, target: .opacity, amount: -0.3)]

        project.layers = [generator, video]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MappingProject.self, from: data)

        XCTAssertEqual(decoded.layers, project.layers)
        XCTAssertEqual(decoded.scans, project.scans)
        XCTAssertEqual(decoded.activeScanID, project.activeScanID)
        XCTAssertEqual(decoded.optics, project.optics)
        XCTAssertEqual(decoded.audience, project.audience)
        XCTAssertEqual(decoded.audio.tempoMode, .manual)
        XCTAssertEqual(decoded.canvasSize, CGSize(width: 1920, height: 1200))
    }

    /// Every file the show needs has to be named, or the media collector deletes it
    /// the next time a layer changes.
    func testEveryReferencedFileIsAccountedFor() {
        let clip = MediaReference(kind: .video, filename: "clip.mov", displayName: "Clip",
                                  pixelSize: .zero, duration: 1)
        let overlay = MediaReference(kind: .image, filename: "overlay.png",
                                     displayName: "Overlay", pixelSize: .zero)
        let track = MediaReference(kind: .video, filename: "song.m4a", displayName: "Song",
                                   pixelSize: .zero, duration: 200)
        let camera = ScanCamera(focalX: 1, focalY: 1, principalX: 0, principalY: 0,
                                imageWidth: 2, imageHeight: 2)

        var project = MappingProject(name: "Files")
        var layer = MappingLayer(name: "Clip", content: .video(clip, VideoPlayback()))
        layer.appearance.texture.pattern = .custom
        layer.appearance.texture.image = overlay
        project.layers = [layer, MappingLayer.make(generator: .waves)]
        project.audio.track = track
        project.scans = [SurfaceScan(name: "Wall", imageFilename: "wall.jpg",
                                     camera: camera, depth: nil)]

        let referenced = project.referencedMedia
        XCTAssertEqual(referenced, ["clip.mov", "overlay.png", "song.m4a", "wall.jpg"])
    }

    /// Generators carry no media at all — that is what lets a follower reproduce a
    /// generator-only show from a clock anchor and a few kilobytes of JSON.
    func testAGeneratorOnlyShowNeedsNoFilesAtAll() {
        var project = MappingProject(name: "Generated")
        project.layers = GeneratorKind.allCases.map { MappingLayer.make(generator: $0) }
        XCTAssertTrue(project.referencedMedia.isEmpty)
        XCTAssertEqual(project.layers.count, 12)
    }
}
