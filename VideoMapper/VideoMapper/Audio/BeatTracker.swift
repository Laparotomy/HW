import Foundation

/// Onset and tempo estimation from spectral flux.
///
/// Deliberately simple: an adaptive threshold over a rolling flux history finds
/// onsets, and the median inter-onset interval (folded into a musical range) gives
/// the tempo. Good enough to drive lights to a four-on-the-floor track, and cheap
/// enough to run alongside video decoding.
///
/// Every stored property is guarded by `lock`, because the two ways beats arrive
/// come from different threads: `process` runs on the audio tap, and `tap` and
/// `reset` run on the main thread behind a button. Tapping the tempo while a track
/// plays would otherwise mutate `fluxHistory` and `intervals` from both at once.
final class BeatTracker {
    /// A consistent view of the tracker, read under one lock.
    ///
    /// Reading `bpm`, `beatEnvelope` and `tempoConfidence` one after another would
    /// take the lock three times and could mix values from either side of a beat.
    struct Snapshot {
        var bpm: Double = 0
        var beatEnvelope: Double = 0
        var tempoConfidence: Double = 0
        var phase: Double = 0
        var didBeat = false
    }

    /// Onsets closer together than this are treated as one hit.
    private let minimumInterval: Double = 0.22
    private let historySize = 43

    /// Guards every stored property below. Not recursive: the `locked` helpers
    /// assume it is already held and must never take it again.
    private let lock = NSLock()

    private var fluxHistory: [Float] = []
    private var lastBeatTime: Double = -1
    private var intervals: [Double] = []

    private var storedBPM: Double = 0
    private var storedConfidence: Double = 0
    private var storedPhase: Double = 0
    private var storedDidBeat = false

    var bpm: Double { withLock { storedBPM } }
    /// How tightly the detected onsets agree, 0...1.
    ///
    /// The estimate itself is always *a* number; this says whether it is worth
    /// trusting. A four-on-the-floor track settles near 1, a rubato piano piece stays
    /// near 0, and the difference is what lets the app follow the music automatically
    /// without lurching whenever detection has a bad few seconds.
    var tempoConfidence: Double { withLock { storedConfidence } }
    /// 0...1 position between the last beat and the next expected one.
    var phase: Double { withLock { storedPhase } }
    var didBeat: Bool { withLock { storedDidBeat } }

    /// Beat-synchronised envelope: 1 on the beat, decaying to 0 before the next.
    var beatEnvelope: Double { withLock { lockedBeatEnvelope } }

    /// Everything the caller needs, taken in one consistent read.
    func snapshot() -> Snapshot {
        withLock {
            Snapshot(bpm: storedBPM,
                     beatEnvelope: lockedBeatEnvelope,
                     tempoConfidence: storedConfidence,
                     phase: storedPhase,
                     didBeat: storedDidBeat)
        }
    }

    func reset() {
        withLock {
            fluxHistory.removeAll()
            intervals.removeAll()
            lastBeatTime = -1
            storedBPM = 0
            storedConfidence = 0
            storedPhase = 0
            storedDidBeat = false
        }
    }

    /// Feeds one analysis window. `time` is show time in seconds.
    func process(flux: Float, at time: Double) {
        withLock {
            storedDidBeat = false
            fluxHistory.append(flux)
            if fluxHistory.count > historySize { fluxHistory.removeFirst() }

            if fluxHistory.count >= 8 {
                let mean = fluxHistory.reduce(0, +) / Float(fluxHistory.count)
                let variance = fluxHistory.reduce(0) { $0 + pow($1 - mean, 2) } / Float(fluxHistory.count)
                // Threshold rides the local mean plus a slice of the deviation, so it
                // tightens in steady passages and loosens through a busy drop.
                let threshold = mean + 1.4 * sqrt(variance)
                if flux > threshold, time - lastBeatTime > minimumInterval {
                    lockedRegisterBeat(at: time)
                }
            }

            lockedUpdatePhase(at: time)
        }
    }

    /// Manual tap-tempo, used when there is no usable audio to analyse.
    func tap(at time: Double) {
        withLock { lockedRegisterBeat(at: time) }
    }

    // MARK: - Locked internals
    //
    // Each of these assumes `lock` is already held by its caller.

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private var lockedBeatEnvelope: Double {
        guard storedBPM > 0 else { return 0 }
        return pow(1 - storedPhase, 2)
    }

    private func lockedRegisterBeat(at time: Double) {
        // `>= 0` rather than `> 0`: the very first tap can legitimately land at
        // time zero, and dropping it would cost an interval.
        if lastBeatTime >= 0 {
            let interval = time - lastBeatTime
            if interval > 0.25, interval < 2.0 {
                intervals.append(interval)
                if intervals.count > 16 { intervals.removeFirst() }
                lockedUpdateTempo()
            }
        }
        lastBeatTime = time
        storedDidBeat = true
    }

    private func lockedUpdateTempo() {
        guard intervals.count >= 4 else { return }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return }
        var estimate = 60.0 / median
        // Fold octave errors into the range people actually count in.
        while estimate < 70 { estimate *= 2 }
        while estimate > 180 { estimate /= 2 }
        // Smooth so a single mis-detected onset does not lurch the tempo.
        storedBPM = storedBPM == 0 ? estimate : storedBPM * 0.8 + estimate * 0.2

        // Spread of the intervals about their median, relative to the median itself.
        // Scaled by 3 so that a 33% spread — sloppy but still recognisably a pulse —
        // lands at zero confidence rather than somewhere ambiguous.
        let deviation = intervals.reduce(0) { $0 + abs($1 - median) } / Double(intervals.count)
        let spread = min(1, deviation / median * 3)
        let measured = (1 - spread) * min(1, Double(intervals.count) / 8)
        storedConfidence = storedConfidence * 0.7 + measured * 0.3
    }

    private func lockedUpdatePhase(at time: Double) {
        guard storedBPM > 0, lastBeatTime >= 0 else { storedPhase = 0; return }
        let period = 60.0 / storedBPM
        let elapsed = time - lastBeatTime
        storedPhase = (elapsed / period).truncatingRemainder(dividingBy: 1)
        if storedPhase < 0 { storedPhase += 1 }
    }
}
