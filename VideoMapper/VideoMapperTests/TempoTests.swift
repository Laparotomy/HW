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
