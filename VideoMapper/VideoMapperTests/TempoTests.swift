import XCTest
@testable import VideoMapper

/// Tempo detection already produced a number before these changes; what it did not do
/// was say whether the number was worth believing. These cover that judgement, because
/// an unsure estimate driving the show is worse than no detection at all.
final class TempoConfidenceTests: XCTestCase {

    /// Feeds a steady pulse and returns the tracker.
    private func trackerWithSteadyBeat(interval: Double, count: Int,
                                       jitter: [Double] = []) -> BeatTracker {
        let tracker = BeatTracker()
        var time = 0.0
        for index in 0..<count {
            tracker.tap(at: time)
            let wobble = jitter.isEmpty ? 0 : jitter[index % jitter.count]
            time += interval + wobble
        }
        return tracker
    }

    func testAFreshTrackerKnowsNothing() {
        let tracker = BeatTracker()
        XCTAssertEqual(tracker.bpm, 0)
        XCTAssertEqual(tracker.tempoConfidence, 0)
    }

    func testASteadyPulseIsRecognised() {
        // 0.5s between beats is 120 BPM.
        let tracker = trackerWithSteadyBeat(interval: 0.5, count: 12)
        XCTAssertEqual(tracker.bpm, 120, accuracy: 2)
        XCTAssertGreaterThan(tracker.tempoConfidence, AudioSettings.confidenceThreshold)
    }

    /// Wildly uneven taps still yield an estimate; confidence is what marks it as one
    /// not to follow.
    func testAnUnevenPulseScoresLowConfidence() {
        let tracker = trackerWithSteadyBeat(interval: 0.5, count: 16,
                                            jitter: [0.35, -0.2, 0.28, -0.24])
        XCTAssertGreaterThan(tracker.bpm, 0)
        XCTAssertLessThan(tracker.tempoConfidence, AudioSettings.confidenceThreshold)
    }

    func testConfidenceStaysInRange() {
        for count in [4, 6, 10, 20] {
            let tracker = trackerWithSteadyBeat(interval: 0.5, count: count)
            XCTAssertGreaterThanOrEqual(tracker.tempoConfidence, 0)
            XCTAssertLessThanOrEqual(tracker.tempoConfidence, 1)
        }
    }

    func testResetClearsTheEstimateAndItsConfidence() {
        let tracker = trackerWithSteadyBeat(interval: 0.5, count: 12)
        tracker.reset()
        XCTAssertEqual(tracker.bpm, 0)
        XCTAssertEqual(tracker.tempoConfidence, 0)
    }

    /// Half- and double-time detections are folded into the range people count in, so
    /// a 75 BPM track is not reported as 37.5.
    func testOctaveErrorsAreFolded() {
        let slow = trackerWithSteadyBeat(interval: 1.6, count: 12)
        XCTAssertGreaterThanOrEqual(slow.bpm, 70)
        XCTAssertLessThanOrEqual(slow.bpm, 180)
    }
}

final class TempoSettingsTests: XCTestCase {

    func testAutomaticIsTheDefault() {
        XCTAssertEqual(AudioSettings().tempoMode, .automatic)
    }

    /// A show saved before `tempoMode` existed has no such key. The synthesised
    /// decoder would reject the file and the user would lose the show.
    func testSettingsSavedBeforeTempoModeExistedStillDecode() throws {
        let json = """
        {"clockSource": "track", "volume": 0.8, "loops": true,
         "manualBPM": 128, "latencyOffset": 0.05}
        """
        let settings = try JSONDecoder().decode(AudioSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.tempoMode, .automatic)
        XCTAssertEqual(settings.manualBPM, 128)
        XCTAssertEqual(settings.clockSource, .track)
        XCTAssertEqual(settings.latencyOffset, 0.05, accuracy: 1e-12)
    }

    func testTempoModeRoundTrips() throws {
        var settings = AudioSettings()
        settings.tempoMode = .manual
        settings.manualBPM = 92
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AudioSettings.self, from: data)
        XCTAssertEqual(decoded.tempoMode, .manual)
        XCTAssertEqual(decoded.manualBPM, 92)
    }

    func testRawValuesAreStable() {
        XCTAssertEqual(TempoMode.automatic.rawValue, "automatic")
        XCTAssertEqual(TempoMode.manual.rawValue, "manual")
    }
}

final class ClipSpeedTests: XCTestCase {

    func testEachLayerCarriesItsOwnSpeed() throws {
        let ref = MediaReference(kind: .video, filename: "clip.mov", displayName: "Clip",
                                 pixelSize: CGSize(width: 1920, height: 1080), duration: 10)
        var half = VideoPlayback(); half.rate = 0.5
        var double = VideoPlayback(); double.rate = 2

        var project = MappingProject(name: "Speeds")
        project.layers = [
            MappingLayer(name: "Slow", content: .video(ref, half)),
            MappingLayer(name: "Fast", content: .video(ref, double))
        ]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MappingProject.self, from: data)

        guard case .video(_, let first) = decoded.layers[0].content,
              case .video(_, let second) = decoded.layers[1].content else {
            return XCTFail("Expected two video layers")
        }
        XCTAssertEqual(first.rate, 0.5)
        XCTAssertEqual(second.rate, 2)
    }

    /// Zero is a freeze, not an invalid value, so the range has to include it.
    func testTheRangeAllowsAFreeze() {
        XCTAssertEqual(VideoPlayback.rateRange.lowerBound, 0)
        XCTAssertGreaterThanOrEqual(VideoPlayback.rateRange.upperBound, 2)
        XCTAssertTrue(VideoPlayback.rateRange.contains(VideoPlayback().rate))
    }

    func testDefaultPlaybackIsRealTimeAndLooping() {
        let playback = VideoPlayback()
        XCTAssertEqual(playback.rate, 1)
        XCTAssertTrue(playback.loops)
        XCTAssertTrue(playback.followsShowClock)
    }
}

/// The tracker is driven from two threads at once: the audio tap feeds `process`
/// while the user can tap tempo or restart Listen mode from the UI. Before the lock
/// that meant two threads inside the same `fluxHistory` and `intervals` arrays,
/// which corrupts them rather than merely mis-reading a beat. These tests fail by
/// trapping, so a regression shows up as a crash in CI rather than a bad number.
final class BeatTrackerConcurrencyTests: XCTestCase {

    private func assertPlausible(_ snapshot: BeatTracker.Snapshot) {
        // After octave folding a live estimate is either nothing yet or musical.
        XCTAssertTrue(snapshot.bpm == 0 || (snapshot.bpm >= 70 && snapshot.bpm <= 180),
                      "bpm out of range: \(snapshot.bpm)")
        XCTAssertGreaterThanOrEqual(snapshot.tempoConfidence, 0)
        XCTAssertLessThanOrEqual(snapshot.tempoConfidence, 1)
        XCTAssertGreaterThanOrEqual(snapshot.phase, 0)
        XCTAssertLessThan(snapshot.phase, 1)
        XCTAssertGreaterThanOrEqual(snapshot.beatEnvelope, 0)
        XCTAssertLessThanOrEqual(snapshot.beatEnvelope, 1)
    }

    /// The envelope is derived from bpm and phase, so a snapshot that mixes one
    /// from before a beat with another from after it would be internally
    /// inconsistent — which is the whole reason `snapshot()` exists.
    func testASnapshotAgreesWithItself() {
        let tracker = BeatTracker()
        var time = 0.0
        for _ in 0..<12 {
            tracker.tap(at: time)
            time += 0.5
        }
        tracker.process(flux: 0.1, at: time)

        let snapshot = tracker.snapshot()
        XCTAssertGreaterThan(snapshot.bpm, 0)
        XCTAssertEqual(snapshot.beatEnvelope, pow(1 - snapshot.phase, 2), accuracy: 1e-12)
        assertPlausible(snapshot)
    }

    func testASnapshotMatchesTheIndividualReads() {
        let tracker = BeatTracker()
        var time = 0.0
        for _ in 0..<8 {
            tracker.tap(at: time)
            time += 0.48
        }
        let snapshot = tracker.snapshot()
        XCTAssertEqual(snapshot.bpm, tracker.bpm)
        XCTAssertEqual(snapshot.tempoConfidence, tracker.tempoConfidence)
        XCTAssertEqual(snapshot.phase, tracker.phase)
        XCTAssertEqual(snapshot.beatEnvelope, tracker.beatEnvelope)
        XCTAssertEqual(snapshot.didBeat, tracker.didBeat)
    }

    func testAFreshSnapshotIsEmpty() {
        let snapshot = BeatTracker().snapshot()
        XCTAssertEqual(snapshot, BeatTracker.Snapshot())
    }

    /// Analysis, a manual tap and a read, all at once — the exact overlap that
    /// tapping tempo during playback produces.
    func testAnalysingAndTappingAtOnceStaysSound() {
        let tracker = BeatTracker()
        let iterations = 600
        let group = DispatchGroup()

        DispatchQueue.global().async(group: group) {
            var time = 0.0
            for index in 0..<iterations {
                tracker.process(flux: index % 5 == 0 ? 8 : 0.2, at: time)
                time += 0.02
            }
        }
        DispatchQueue.global().async(group: group) {
            var time = 0.0
            for _ in 0..<iterations {
                tracker.tap(at: time)
                time += 0.5
            }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<iterations { _ = tracker.snapshot() }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        assertPlausible(tracker.snapshot())
    }

    /// Listen mode resets the tracker from the main thread while the tap thread is
    /// still delivering buffers.
    func testResettingDuringAnalysisStaysSound() {
        let tracker = BeatTracker()
        let iterations = 600
        let group = DispatchGroup()

        DispatchQueue.global().async(group: group) {
            var time = 0.0
            for index in 0..<iterations {
                tracker.process(flux: index % 5 == 0 ? 8 : 0.2, at: time)
                time += 0.02
            }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<iterations { tracker.reset() }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        assertPlausible(tracker.snapshot())
    }
}
