import Accelerate
import AVFoundation

/// Frequency-band energies for one analysis window, each roughly 0...1.
struct Spectrum: Equatable {
    var level: Float = 0
    var bass: Float = 0
    var mid: Float = 0
    var treble: Float = 0
    /// Sum of positive changes in magnitude since the previous window. This is the
    /// onset signal the beat tracker thresholds.
    var flux: Float = 0

    static let silent = Spectrum()
}

/// Windowed FFT over an audio tap, reduced to three bands plus spectral flux.
///
/// Samples arrive in whatever buffer size CoreAudio feels like using, so they are
/// pushed through a ring buffer and analysed in fixed 1024-sample hops.
final class SpectrumAnalyzer {
    private let fftSize = 1024
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    private var window: [Float]
    private var ring: [Float]
    private var ringFill = 0

    private var realParts: [Float]
    private var imagParts: [Float]
    private var magnitudes: [Float]
    private var previousMagnitudes: [Float]

    /// Band edges in Hz. Bass is deliberately narrow: kick drums live there and it
    /// makes the default bass-to-intensity route feel like it is hitting the beat.
    private let bassRange: ClosedRange<Float> = 30...160
    private let midRange: ClosedRange<Float> = 160...2000
    private let trebleRange: ClosedRange<Float> = 2000...8000

    init() {
        log2n = vDSP_Length(log2(Float(fftSize)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        ring = [Float](repeating: 0, count: fftSize)
        realParts = [Float](repeating: 0, count: fftSize / 2)
        imagParts = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        previousMagnitudes = [Float](repeating: 0, count: fftSize / 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Feeds a tap buffer in and returns a spectrum once a full window is available.
    func process(buffer: AVAudioPCMBuffer, sampleRate: Double) -> Spectrum? {
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return nil }

        var result: Spectrum?
        var index = 0
        while index < count {
            let chunk = min(fftSize - ringFill, count - index)
            ring.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                (base + ringFill).update(from: channel + index, count: chunk)
            }
            ringFill += chunk
            index += chunk
            if ringFill == fftSize {
                result = analyseWindow(sampleRate: sampleRate)
                ringFill = 0
            }
        }
        return result
    }

    private func analyseWindow(sampleRate: Double) -> Spectrum {
        var windowed = [Float](repeating: 0, count: fftSize)
        vDSP_vmul(ring, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

        let half = fftSize / 2
        realParts.withUnsafeMutableBufferPointer { realBuffer in
            imagParts.withUnsafeMutableBufferPointer { imagBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!,
                                            imagp: imagBuffer.baseAddress!)
                // Real-to-complex packing: the real signal is reinterpreted as
                // interleaved complex pairs, which is what vDSP_fft_zrip expects.
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { mags in
                    vDSP_zvabs(&split, 1, mags.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // vDSP's real FFT returns values scaled by 2N; normalise so results are
        // comparable across window sizes. The returning form avoids passing the
        // same buffer as both input and inout output.
        magnitudes = vDSP.multiply(Float(1.0) / Float(fftSize), magnitudes)

        var spectrum = Spectrum()
        let binWidth = Float(sampleRate) / Float(fftSize)
        spectrum.bass = compress(energy(in: bassRange, binWidth: binWidth))
        spectrum.mid = compress(energy(in: midRange, binWidth: binWidth))
        spectrum.treble = compress(energy(in: trebleRange, binWidth: binWidth))

        var rms: Float = 0
        vDSP_rmsqv(ring, 1, &rms, vDSP_Length(fftSize))
        spectrum.level = compress(rms * 4)

        var flux: Float = 0
        for i in 0..<half {
            let delta = magnitudes[i] - previousMagnitudes[i]
            if delta > 0 { flux += delta }
        }
        spectrum.flux = flux
        previousMagnitudes = magnitudes

        return spectrum
    }

    private func energy(in range: ClosedRange<Float>, binWidth: Float) -> Float {
        let lower = max(1, Int(range.lowerBound / binWidth))
        let upper = min(magnitudes.count - 1, Int(range.upperBound / binWidth))
        guard upper > lower else { return 0 }
        var sum: Float = 0
        for i in lower...upper { sum += magnitudes[i] }
        return sum / Float(upper - lower + 1)
    }

    /// Music has a huge dynamic range; a soft knee keeps quiet passages visible
    /// without pinning loud ones at 1.0.
    private func compress(_ value: Float) -> Float {
        let scaled = value * 24
        return min(1, scaled / (1 + scaled) * 1.6)
    }
}
