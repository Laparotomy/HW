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

/// What the editing stage draws.
///
/// The picture and the mapping get in each other's way: a bright clip swallows a thin
/// grid line, and grids over every layer hide the thing being judged. These pin the
/// three answers so a future tweak cannot quietly leave the stage with nothing on it.
@MainActor
final class StageDisplayTests: XCTestCase {

    func testContentAloneDrawsNoMapping() {
        let mode = ShowController.StageDisplay.content
        XCTAssertFalse(mode.showsGrid)
        XCTAssertEqual(mode.scrimOpacity, 0, accuracy: 1e-12)
    }

    /// Grid mode has to knock the picture back, or the lines are invisible over a
    /// bright clip — which is the case the mode exists for.
    func testGridModeDimsThePictureBehindIt() {
        let mode = ShowController.StageDisplay.grid
        XCTAssertTrue(mode.showsGrid)
        XCTAssertGreaterThan(mode.scrimOpacity, 0.5)
        XCTAssertLessThan(mode.scrimOpacity, 1)
    }

    /// Both is the working default, so it must not dim anything: what you see has to
    /// be what the projector puts on the wall.
    func testBothShowsTheMappingOverAnUndimmedPicture() {
        let mode = ShowController.StageDisplay.both
        XCTAssertTrue(mode.showsGrid)
        XCTAssertEqual(mode.scrimOpacity, 0, accuracy: 1e-12)
    }

    func testEveryModeIsLabelledForThePicker() {
        var names = Set<String>()
        var symbols = Set<String>()
        for mode in ShowController.StageDisplay.allCases {
            XCTAssertFalse(mode.displayName.isEmpty, mode.rawValue)
            XCTAssertFalse(mode.symbolName.isEmpty, mode.rawValue)
            names.insert(mode.displayName)
            symbols.insert(mode.symbolName)
        }
        // The expanded stage picks between these by icon alone.
        XCTAssertEqual(names.count, ShowController.StageDisplay.allCases.count)
        XCTAssertEqual(symbols.count, ShowController.StageDisplay.allCases.count)
    }

    /// Exactly one mode hides the mapping. If two did, the switch would have a dead
    /// position in it.
    func testOnlyOneModeHidesTheMapping() {
        let hidden = ShowController.StageDisplay.allCases.filter { !$0.showsGrid }
        XCTAssertEqual(hidden, [.content])
    }
}

/// Holding the show still until the music starts.
///
/// The failure mode is a show that never moves and says nothing about why, so these
/// walk the gate through the cases that actually happen in a room: a track paused
/// mid-set, a gap between two tracks, a quiet passage, and a PA that has not started.
final class MusicGateTests: XCTestCase {

    /// A gate that has heard nothing must read as silent, not as having just gone
    /// quiet — otherwise a show gated on the microphone would run for one hold
    /// before freezing, which looks like a crash rather than a setting.
    func testAGateThatHasHeardNothingIsSilent() {
        let gate = MusicGate()
        XCTAssertFalse(gate.heardRecently(at: 0))
        XCTAssertFalse(gate.heardRecently(at: 1_000_000))
        XCTAssertFalse(gate.isSounding(clock: .listen, hasTrack: false,
                                       trackIsPlaying: false, at: 0))
    }

    func testSomethingAboveTheThresholdCountsAsHeard() {
        var gate = MusicGate()
        gate.observe(level: 0.6, threshold: 0.35, at: 10)
        XCTAssertTrue(gate.heardRecently(at: 10))
        XCTAssertTrue(gate.isSounding(clock: .listen, hasTrack: false,
                                      trackIsPlaying: false, at: 10))
    }

    func testRoomNoiseBelowTheThresholdIsNotMusic() {
        var gate = MusicGate()
        gate.observe(level: 0.2, threshold: 0.35, at: 10)
        XCTAssertFalse(gate.heardRecently(at: 10))
    }

    /// The threshold is a floor, not a ceiling: exactly at it is still silence, so a
    /// gate set to the room's own reading does not chatter on and off.
    func testTheThresholdItselfIsNotEnough() {
        var gate = MusicGate()
        gate.observe(level: 0.35, threshold: 0.35, at: 10)
        XCTAssertFalse(gate.heardRecently(at: 10))
    }

    /// A break between two phrases, or the half-second a DJ spends cutting the bass,
    /// must not freeze and restart the show.
    func testTheShowKeepsRunningThroughAShortGap() {
        var gate = MusicGate(hold: 0.8)
        gate.observe(level: 1, threshold: 0.35, at: 10)
        gate.observe(level: 0, threshold: 0.35, at: 10.5)
        XCTAssertTrue(gate.heardRecently(at: 10.5))
        XCTAssertTrue(gate.heardRecently(at: 10.79))
    }

    func testTheShowStopsOnceTheHoldRunsOut() {
        var gate = MusicGate(hold: 0.8)
        gate.observe(level: 1, threshold: 0.35, at: 10)
        XCTAssertFalse(gate.heardRecently(at: 10.8))
        XCTAssertFalse(gate.heardRecently(at: 12))
    }

    func testEachSoundRestartsTheHold() {
        var gate = MusicGate(hold: 0.8)
        gate.observe(level: 1, threshold: 0.35, at: 10)
        gate.observe(level: 1, threshold: 0.35, at: 10.6)
        // Without the restart this would already be past the hold from t = 10.
        XCTAssertTrue(gate.heardRecently(at: 11.2))
    }

    // MARK: - Per clock source

    /// Free run has no music to wait for, and its analyser is not even running.
    /// Gating there could only ever freeze the show for good.
    func testFreeRunIsNeverGated() {
        let gate = MusicGate()
        XCTAssertTrue(gate.isSounding(clock: .freeRun, hasTrack: false,
                                      trackIsPlaying: false, at: 0))
        XCTAssertTrue(gate.isSounding(clock: .freeRun, hasTrack: true,
                                      trackIsPlaying: false, at: 10_000))
    }

    /// With a file loaded the answer is exact, and it does not depend on what the
    /// microphone can hear — a show run from a phone on a stand, in a loud room,
    /// must not be told its own paused track is playing.
    func testALoadedTrackAnswersFromTheTransport() {
        var gate = MusicGate()
        gate.observe(level: 1, threshold: 0.35, at: 10)

        XCTAssertTrue(gate.isSounding(clock: .track, hasTrack: true,
                                      trackIsPlaying: true, at: 10))
        XCTAssertFalse(gate.isSounding(clock: .track, hasTrack: true,
                                       trackIsPlaying: false, at: 10))
    }

    /// The Track clock with no file loaded is someone who has chosen it and not got
    /// there yet. Falling back to the microphone is better than freezing outright.
    func testTheTrackClockFallsBackToTheMicrophoneWithNoFile() {
        var gate = MusicGate()
        gate.observe(level: 1, threshold: 0.35, at: 10)
        XCTAssertTrue(gate.isSounding(clock: .track, hasTrack: false,
                                      trackIsPlaying: false, at: 10))
        XCTAssertFalse(gate.isSounding(clock: .track, hasTrack: false,
                                       trackIsPlaying: false, at: 99))
    }

    func testListenAlwaysAnswersFromTheMicrophone() {
        var gate = MusicGate()
        gate.observe(level: 1, threshold: 0.35, at: 10)
        // Even with a file loaded and playing: Listen means the room is the source.
        XCTAssertTrue(gate.isSounding(clock: .listen, hasTrack: true,
                                      trackIsPlaying: false, at: 10))
        XCTAssertFalse(gate.isSounding(clock: .listen, hasTrack: true,
                                       trackIsPlaying: true, at: 99))
    }

    func testResettingForgetsWhatItHeard() {
        var gate = MusicGate()
        gate.observe(level: 1, threshold: 0.35, at: 10)
        gate.reset()
        XCTAssertFalse(gate.heardRecently(at: 10))
    }

    func testTheDefaultHoldIsTheOneTheSettingsPublish() {
        XCTAssertEqual(MusicGate().hold, AudioSettings.musicGateHold, accuracy: 1e-12)
    }
}
