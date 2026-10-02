import AVFoundation
import XCTest
@testable import VideoMapper

/// The analyser is fed by an audio tap, and a tap's buffer size is a request rather
/// than a promise: the size CoreAudio actually delivers depends on the device, the
/// route and the session, and is routinely several windows' worth. These pin the
/// behaviour that has to hold whatever size arrives, because the symptom of getting it
/// wrong is a detected tempo that is simply a wrong number — not a crash, and not
/// something a glance at the readout would catch.
final class AnalysisWindowTests: XCTestCase {

    private let sampleRate: Double = 48_000

    /// A buffer of `frames` samples of a tone, which is enough signal for the FFT to
    /// have something to say about.
    private func buffer(frames: Int) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                      frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<frames {
                let phase = 2 * Double.pi * 220 * Double(index) / sampleRate
                channel[index] = Float(sin(phase) * 0.5)
            }
        }
        return buffer
    }

    func testOneWindowOfSamplesYieldsOneWindow() {
        let analyzer = SpectrumAnalyzer()
        XCTAssertEqual(analyzer.process(buffer: buffer(frames: analyzer.windowSize),
                                        sampleRate: sampleRate).count, 1)
    }

    /// The case that was wrong: a larger buffer must report every window it completed,
    /// because each one stands for a hop of elapsed time on the beat tracker's clock.
    func testALargerBufferYieldsEveryWindowItCompleted() {
        let analyzer = SpectrumAnalyzer()
        let windows = analyzer.process(buffer: buffer(frames: analyzer.windowSize * 4),
                                       sampleRate: sampleRate)
        XCTAssertEqual(windows.count, 4)
    }

    /// Short buffers accumulate instead of being analysed early, so a window is always
    /// a whole window.
    func testAShortBufferWaitsForTheRestOfItsWindow() {
        let analyzer = SpectrumAnalyzer()
        let half = analyzer.windowSize / 2
        XCTAssertTrue(analyzer.process(buffer: buffer(frames: half),
                                       sampleRate: sampleRate).isEmpty)
        XCTAssertEqual(analyzer.process(buffer: buffer(frames: half),
                                        sampleRate: sampleRate).count, 1)
    }

    /// A ragged size leaves its remainder in the ring for the next buffer rather than
    /// dropping it, so the elapsed-time accounting stays exact over a long set.
    func testARaggedBufferCarriesItsRemainderForward() {
        let analyzer = SpectrumAnalyzer()
        let size = analyzer.windowSize
        XCTAssertEqual(analyzer.process(buffer: buffer(frames: size + size / 2),
                                        sampleRate: sampleRate).count, 1)
        XCTAssertEqual(analyzer.process(buffer: buffer(frames: size / 2),
                                        sampleRate: sampleRate).count, 1)
    }

    func testAnEmptyBufferYieldsNothing() {
        let analyzer = SpectrumAnalyzer()
        XCTAssertTrue(analyzer.process(buffer: buffer(frames: 0),
                                       sampleRate: sampleRate).isEmpty)
    }
}
