import XCTest
@testable import VideoMapper

/// Snapping exists for one reason: two mapped surfaces that meet on the wall have to
/// meet exactly. A gap of one pixel is a black hairline, an overlap of one pixel is a
/// bright one, and neither is fixable by eye from where you stand next to a projector.
final class PointSnappingTests: XCTestCase {

    private func layer(named name: String, size: Double,
                       center: CGPoint = CGPoint(x: 0.5, y: 0.5)) -> MappingLayer {
        var layer = MappingLayer(name: name)
        layer.transform.center = center
        layer.transform.size = CGSize(width: size, height: size)
        return layer
    }

    // MARK: - Choosing

    func testADragOutsideTheRadiusIsLeftAlone() {
        let candidates = [PointSnapping.Candidate(position: CGPoint(x: 0.5, y: 0.5),
                                                  target: .canvasGuide)]
        XCTAssertNil(PointSnapping.snap(CGPoint(x: 0.7, y: 0.5), to: candidates, radius: 0.02))
    }

    func testADragInsideTheRadiusLandsExactlyOnTheCandidate() {
        let candidates = [PointSnapping.Candidate(position: CGPoint(x: 0.5, y: 0.5),
                                                  target: .canvasGuide)]
        let result = PointSnapping.snap(CGPoint(x: 0.505, y: 0.497),
                                        to: candidates, radius: 0.02)
        // Exactly, not nearly: a coordinate that is merely close leaves the seam.
        XCTAssertEqual(result?.position, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(result?.target, .canvasGuide)
    }

    /// With several surfaces meeting at a corner, the one under the finger is the one
    /// meant. Taking whichever came first in the list would feel arbitrary.
    func testTheNearestCandidateWins() {
        let candidates = [
            PointSnapping.Candidate(position: CGPoint(x: 0.52, y: 0.5),
                                    target: .otherLayer(name: "Far")),
            PointSnapping.Candidate(position: CGPoint(x: 0.505, y: 0.5),
                                    target: .otherLayer(name: "Near"))
        ]
        let result = PointSnapping.snap(CGPoint(x: 0.5, y: 0.5), to: candidates, radius: 0.05)
        XCTAssertEqual(result?.target, .otherLayer(name: "Near"))
    }

    func testNoCandidatesMeansNoSnap() {
        XCTAssertNil(PointSnapping.snap(CGPoint(x: 0.5, y: 0.5), to: []))
    }

    /// Normalized coordinates are stretched by the frame's shape. Without correcting
    /// for it, a snap on a 16:9 canvas would reach nearly twice as far sideways as it
    /// does vertically — lopsided in exactly the way a projector makes obvious.
    func testTheRadiusIsRoundOnTheWallNotInStoredUnits() {
        let candidates = [PointSnapping.Candidate(position: CGPoint(x: 0.53, y: 0.5),
                                                  target: .canvasGuide)]
        let position = CGPoint(x: 0.5, y: 0.5)

        XCTAssertNotNil(PointSnapping.snap(position, to: candidates, radius: 0.04, aspect: 1))
        XCTAssertNil(PointSnapping.snap(position, to: candidates,
                                        radius: 0.04, aspect: 16.0 / 9.0))

        // The same distance vertically is unaffected by the aspect, by construction.
        let above = [PointSnapping.Candidate(position: CGPoint(x: 0.5, y: 0.53),
                                             target: .canvasGuide)]
        XCTAssertNotNil(PointSnapping.snap(position, to: above,
                                           radius: 0.04, aspect: 16.0 / 9.0))
    }

    func testAnUnusableAspectFallsBackToSquare() {
        let candidates = [PointSnapping.Candidate(position: CGPoint(x: 0.53, y: 0.5),
                                                  target: .canvasGuide)]
        XCTAssertNotNil(PointSnapping.snap(CGPoint(x: 0.5, y: 0.5), to: candidates,
                                           radius: 0.04, aspect: 0))
        XCTAssertNotNil(PointSnapping.snap(CGPoint(x: 0.5, y: 0.5), to: candidates,
                                           radius: 0.04, aspect: .nan))
    }

    // MARK: - Where candidates come from

    func testAnUnsubdividedLayerOffersItsFourCorners() {
        let other = layer(named: "Wall", size: 0.5)
        let candidates = PointSnapping.candidates(in: [other], excluding: nil)
        XCTAssertEqual(candidates.count, 4)
        XCTAssertTrue(candidates.allSatisfy { $0.target == .otherLayer(name: "Wall") })
    }

    func testASubdividedLayerOffersEveryControlPoint() {
        var other = layer(named: "Column", size: 0.5)
        other.transform.setMeshDivisions(columns: 2, rows: 2)
        let candidates = PointSnapping.candidates(in: [other], excluding: nil)
        XCTAssertEqual(candidates.count, 9)
    }

    /// The layer being dragged must not offer its own corners as targets, or a point
    /// would snap onto the place it just left.
    func testTheDraggedLayerIsExcluded() {
        let a = layer(named: "A", size: 0.5)
        let b = layer(named: "B", size: 0.4)
        let candidates = PointSnapping.candidates(in: [a, b], excluding: a.id)
        XCTAssertEqual(candidates.count, 4)
        XCTAssertTrue(candidates.allSatisfy { $0.target == .otherLayer(name: "B") })
    }

    /// A hidden layer is not on the wall, so there is no seam to close against it.
    func testHiddenLayersOfferNothing() {
        var hidden = layer(named: "Hidden", size: 0.5)
        hidden.isVisible = false
        XCTAssertTrue(PointSnapping.candidates(in: [hidden], excluding: nil).isEmpty)
    }

    func testSelfCandidatesSkipThePointInHand() {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 2, rows: 2)
        let all = PointSnapping.selfCandidates(of: transform, excluding: nil)
        XCTAssertEqual(all.count, 9)

        let withoutCentre = PointSnapping.selfCandidates(of: transform, excluding: 4)
        XCTAssertEqual(withoutCentre.count, 8)
        XCTAssertFalse(withoutCentre.contains { $0.position == transform.meshPoints()[4] })
    }

    func testAPlainQuadHasNoPointsToSnapToItself() {
        XCTAssertTrue(PointSnapping.selfCandidates(of: LayerTransform(), excluding: nil).isEmpty)
    }

    /// The commonest alignment of all is "flush with the edge of the frame", and
    /// hitting that by eye costs more attempts than it should.
    func testCanvasGuidesCoverTheEdgesTheCentreAndTheCorners() {
        let candidates = PointSnapping.canvasCandidates(near: CGPoint(x: 0.2, y: 0.3))
        XCTAssertTrue(candidates.allSatisfy { $0.target == .canvasGuide })
        // A vertical guide keeps the drag's own height.
        XCTAssertTrue(candidates.contains { $0.position == CGPoint(x: 0, y: 0.3) })
        XCTAssertTrue(candidates.contains { $0.position == CGPoint(x: 0.2, y: 1) })
        XCTAssertTrue(candidates.contains { $0.position == CGPoint(x: 0.5, y: 0.3) })
        // And the corners are offered as a single exact stop.
        XCTAssertTrue(candidates.contains { $0.position == CGPoint(x: 1, y: 1) })
    }

    func testEveryTargetCanNameItself() {
        XCTAssertEqual(PointSnapping.Target.otherLayer(name: "Left pillar").label, "Left pillar")
        XCTAssertEqual(PointSnapping.Target.sameLayer.label, "Same layer")
        XCTAssertEqual(PointSnapping.Target.canvasGuide.label, "Canvas")
    }

    // MARK: - End to end

    /// Two surfaces that share an edge end up sharing a coordinate, to the bit.
    func testTwoSurfacesMeetOnExactlyTheSameCoordinate() throws {
        let left = layer(named: "Left", size: 0.4, center: CGPoint(x: 0.3, y: 0.5))
        var right = layer(named: "Right", size: 0.4, center: CGPoint(x: 0.72, y: 0.5))

        let seam = left.transform.quad().corners[1]   // left's top-right
        let candidates = PointSnapping.candidates(in: [left], excluding: right.id)

        // A drag that comes close but not exact — which is all a fingertip can do.
        let sloppy = CGPoint(x: seam.x + 0.006, y: seam.y - 0.004)
        let result = PointSnapping.snap(sloppy, to: candidates, radius: 0.03)
        right.transform.setCorner(0, to: try XCTUnwrap(result).position)

        XCTAssertEqual(right.transform.quad().corners[0].x, seam.x, accuracy: 1e-6)
        XCTAssertEqual(right.transform.quad().corners[0].y, seam.y, accuracy: 1e-6)
    }

    /// Snapping must not be able to fold a cell: the drag still has to pass the
    /// drawability check afterwards, and a snap that lands somewhere impossible is
    /// simply refused like any other drag.
    func testASnapOntoAFoldingPositionIsStillRefusedByTheLayer() {
        var transform = LayerTransform()
        transform.setMeshDivisions(columns: 2, rows: 2)
        let corner = transform.mesh.index(column: 0, row: 0)

        let candidates = [PointSnapping.Candidate(position: CGPoint(x: 0.9, y: 0.9),
                                                  target: .canvasGuide)]
        let landing = PointSnapping.snap(CGPoint(x: 0.895, y: 0.895),
                                         to: candidates, radius: 0.03)
        XCTAssertEqual(landing?.position, CGPoint(x: 0.9, y: 0.9))
        XCTAssertFalse(transform.meshIsDrawable(movingPointAt: corner,
                                                to: CGPoint(x: 0.9, y: 0.9)))
    }
}

/// Holding the show still until the music starts.
final class MusicGateSettingsTests: XCTestCase {

    func testTheGateIsOffByDefault() {
        let settings = AudioSettings()
        XCTAssertFalse(settings.animateOnlyWithMusic)
        XCTAssertEqual(settings.musicGateLevel, 0.35, accuracy: 1e-12)
    }

    func testTheGateRoundTrips() throws {
        var settings = AudioSettings()
        settings.animateOnlyWithMusic = true
        settings.musicGateLevel = 0.62
        settings.clockSource = .listen

        let decoded = try JSONDecoder().decode(AudioSettings.self,
                                               from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }

    /// A show saved before the gate existed still has to open.
    func testASettingsBlockWithoutTheGateStillDecodes() throws {
        let json = """
        {"clockSource": "listen", "volume": 1, "loops": true,
         "tempoMode": "automatic", "manualBPM": 128, "latencyOffset": 0}
        """
        let settings = try JSONDecoder().decode(AudioSettings.self, from: Data(json.utf8))
        XCTAssertFalse(settings.animateOnlyWithMusic)
        XCTAssertEqual(settings.musicGateLevel, 0.35, accuracy: 1e-12)
        XCTAssertEqual(settings.manualBPM, 128, accuracy: 1e-12)
    }

    /// The hold has to be long enough that a bar without a kick is not a stutter, and
    /// short enough that the end of a set is not a long stare at a moving screen.
    func testTheHoldIsShortButNotInstant() {
        XCTAssertGreaterThan(AudioSettings.musicGateHold, 0.25)
        XCTAssertLessThan(AudioSettings.musicGateHold, 3)
    }
}
