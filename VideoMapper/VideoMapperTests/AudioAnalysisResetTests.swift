import AVFoundation
import XCTest
@testable import VideoMapper

/// Analysis state has to be forgotten when analysis stops, or the next run starts from
/// whatever the last one was hearing. On a stage that reads as the show reacting to
/// music that is no longer playing, which looks like a modulation bug rather than an
/// audio one — so these pin the forgetting itself.
final class AudioAnalysisResetTests: XCTestCase {

    private let sampleRate: Double = 48_000

    private func buffer(frames: Int, amplitude: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                let phase = 2 * Double.pi * 220 * Double(index) / sampleRate
                channel[index] = Float(sin(phase) * amplitude)
            }
        }
        return buffer
    }

    /// Half a window left in the ring from the last run must not be glued onto the
    /// first half-window of the next one.
    func testResetDropsThePartFilledWindow() {
        let analyzer = SpectrumAnalyzer()
        let half = analyzer.windowSize / 2
        XCTAssertTrue(analyzer.process(buffer: buffer(frames: half, amplitude: 0.5),
                                       sampleRate: sampleRate).isEmpty)
        analyzer.reset()
        XCTAssertTrue(analyzer.process(buffer: buffer(frames: half, amplitude: 0.5),
                                       sampleRate: sampleRate).isEmpty,
                      "the dropped half window should not complete the next one")
    }

    /// Flux is measured against the previous window. Carried across a stop, the first
    /// window of the next run is compared with music from minutes ago — so a run that
    /// opens on a loud passage reads as no onset at all, or a quiet one as an enormous
    /// one. After a reset the first window has to read exactly as it does on an
    /// analyser that has never seen anything.
    func testResetMakesTheNextRunStartFromSilence() {
        let size = SpectrumAnalyzer().windowSize

        let fresh = SpectrumAnalyzer()
        guard let firstEver = fresh.process(buffer: buffer(frames: size, amplitude: 0.5),
                                            sampleRate: sampleRate).last else {
            return XCTFail("a full window should have been analysed")
        }

        let reused = SpectrumAnalyzer()
        _ = reused.process(buffer: buffer(frames: size, amplitude: 0.5), sampleRate: sampleRate)
        reused.reset()
        guard let afterReset = reused.process(buffer: buffer(frames: size, amplitude: 0.5),
                                              sampleRate: sampleRate).last else {
            return XCTFail("a full window should have been analysed")
        }

        XCTAssertGreaterThan(firstEver.flux, 0, "a tone against silence is an onset")
        XCTAssertEqual(afterReset.flux, firstEver.flux, accuracy: firstEver.flux * 0.01)
    }

    /// The tracker is reset alongside the analyser, so a tempo measured from onsets in
    /// the last run is not still being reported in the next one.
    func testAResetTrackerReportsNoTempo() {
        let tracker = BeatTracker()
        var time = 0.0
        for _ in 0..<12 {
            tracker.tap(at: time)
            time += 0.5
        }
        XCTAssertGreaterThan(tracker.bpm, 0)

        tracker.reset()
        XCTAssertEqual(tracker.bpm, 0)
        XCTAssertEqual(tracker.tempoConfidence, 0)
        XCTAssertEqual(tracker.beatEnvelope, 0)
    }

    /// What a cleared feature set has to mean downstream: nothing driving anything,
    /// and a music gate that reads the room as silent.
    func testClearedFeaturesDriveNothing() {
        let features = AudioFeatures()
        for source in ModulationSource.allCases {
            XCTAssertEqual(features.value(for: source), 0, "\(source) should read as silent")
        }

        var gate = MusicGate()
        gate.observe(level: features.level, threshold: 0.35, at: 10)
        XCTAssertFalse(gate.isSounding(clock: .listen, hasTrack: false, trackIsPlaying: false,
                                       at: 10))
    }
}
