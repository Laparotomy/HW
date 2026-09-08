import Foundation

/// Onset and tempo estimation from spectral flux.
///
/// Deliberately simple: an adaptive threshold over a rolling flux history finds
/// onsets, and the median inter-onset interval (folded into a musical range) gives
/// the tempo. Good enough to drive lights to a four-on-the-floor track, and cheap
/// enough to run alongside video decoding.
final class BeatTracker {
    /// Onsets closer together than this are treated as one hit.
    private let minimumInterval: Double = 0.22
    private let historySize = 43

    private var fluxHistory: [Float] = []
    private var lastBeatTime: Double = -1
    private var intervals: [Double] = []

    private(set) var bpm: Double = 0
    /// 0...1 position between the last beat and the next expected one.
    private(set) var phase: Double = 0
    private(set) var didBeat = false

    func reset() {
        fluxHistory.removeAll()
        intervals.removeAll()
        lastBeatTime = -1
        bpm = 0
        phase = 0
        didBeat = false
    }

    /// Feeds one analysis window. `time` is show time in seconds.
    func process(flux: Float, at time: Double) {
        didBeat = false
        fluxHistory.append(flux)
        if fluxHistory.count > historySize { fluxHistory.removeFirst() }

        if fluxHistory.count >= 8 {
            let mean = fluxHistory.reduce(0, +) / Float(fluxHistory.count)
            let variance = fluxHistory.reduce(0) { $0 + pow($1 - mean, 2) } / Float(fluxHistory.count)
            // Threshold rides the local mean plus a slice of the deviation, so it
            // tightens in steady passages and loosens through a busy drop.
            let threshold = mean + 1.4 * sqrt(variance)
            if flux > threshold, time - lastBeatTime > minimumInterval {
                registerBeat(at: time)
            }
        }

        updatePhase(at: time)
    }

    /// Manual tap-tempo, used when there is no usable audio to analyse.
    func tap(at time: Double) {
        registerBeat(at: time)
    }

    private func registerBeat(at time: Double) {
        // `>= 0` rather than `> 0`: the very first tap can legitimately land at
        // time zero, and dropping it would cost an interval.
        if lastBeatTime >= 0 {
            let interval = time - lastBeatTime
            if interval > 0.25, interval < 2.0 {
                intervals.append(interval)
                if intervals.count > 16 { intervals.removeFirst() }
                updateTempo()
            }
        }
        lastBeatTime = time
        didBeat = true
    }

    private func updateTempo() {
        guard intervals.count >= 4 else { return }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return }
        var estimate = 60.0 / median
        // Fold octave errors into the range people actually count in.
        while estimate < 70 { estimate *= 2 }
        while estimate > 180 { estimate /= 2 }
        // Smooth so a single mis-detected onset does not lurch the tempo.
        bpm = bpm == 0 ? estimate : bpm * 0.8 + estimate * 0.2
    }

    private func updatePhase(at time: Double) {
        guard bpm > 0, lastBeatTime >= 0 else { phase = 0; return }
        let period = 60.0 / bpm
        let elapsed = time - lastBeatTime
        phase = (elapsed / period).truncatingRemainder(dividingBy: 1)
        if phase < 0 { phase += 1 }
    }

    /// Beat-synchronised envelope: 1 on the beat, decaying to 0 before the next.
    var beatEnvelope: Double {
        guard bpm > 0 else { return 0 }
        return pow(1 - phase, 2)
    }
}
