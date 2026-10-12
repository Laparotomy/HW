import Foundation

/// Onset and tempo estimation from spectral flux.
///
/// Deliberately simple: an adaptive threshold over a rolling flux history finds
/// onsets, and the median inter-onset interval (folded into a musical range) gives
/// the tempo. Good enough to drive lights to a four-on-the-floor track, and cheap
/// enough to run alongside video decoding.
///
/// **Two threads drive this.** The audio tap feeds `process`, while the main thread
/// can call `tap` or `reset` at any moment — tapping tempo during playback puts two
/// threads inside the same `fluxHistory` and `intervals` arrays at once, and
/// `append`/`removeFirst` racing each other corrupts the buffer or traps rather
/// than merely glitching the beat. So one lock guards every field, and `snapshot()`
/// reads the whole estimate in a single acquisition: a caller can never pair a bpm
/// from before a beat with an envelope from after it.
///
/// A lock is acceptable on the audio side because `installTap` delivers buffers on
/// its own queue rather than the render thread, and this code allocates anyway (the
/// flux history grows, the intervals sort) — none of it was ever real-time safe.
/// Safe to share: every field is guarded by `lock`, which is what the
/// `@unchecked` here is asserting.
final class BeatTracker: @unchecked Sendable {
    /// The whole estimate, as of one instant.
    struct Snapshot: Equatable {
        var bpm: Double = 0
        var tempoConfidence: Double = 0
        var phase: Double = 0
        var beatEnvelope: Double = 0
        var didBeat = false
    }

    /// Onsets closer together than this are treated as one hit.
    private let minimumInterval: Double = 0.22
    private let historySize = 43

    private let lock = NSLock()

    // Everything below is guarded by `lock`.
    private var fluxHistory: [Float] = []
    private var lastBeatTime: Double = -1
    private var intervals: [Double] = []
    private var currentBPM: Double = 0
    private var currentConfidence: Double = 0
    private var currentPhase: Double = 0
    private var beatFlag = false

    // MARK: - Reading

    /// Every output at once. Prefer this over the individual properties when more
    /// than one of them is used together.
    func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(bpm: currentBPM,
                     tempoConfidence: currentConfidence,
                     phase: currentPhase,
                     beatEnvelope: lockedEnvelope(),
                     didBeat: beatFlag)
        }
    }

    var bpm: Double { lock.withLock { currentBPM } }

    /// How tightly the detected onsets agree, 0...1.
    ///
    /// The estimate itself is always *a* number; this says whether it is worth
    /// trusting. A four-on-the-floor track settles near 1, a rubato piano piece stays
    /// near 0, and the difference is what lets the app follow the music automatically
    /// without lurching whenever detection has a bad few seconds.
    var tempoConfidence: Double { lock.withLock { currentConfidence } }

    /// 0...1 position between the last beat and the next expected one.
    var phase: Double { lock.withLock { currentPhase } }

    var didBeat: Bool { lock.withLock { beatFlag } }

    /// Beat-synchronised envelope: 1 on the beat, decaying to 0 before the next.
    var beatEnvelope: Double { lock.withLock { lockedEnvelope() } }

    // MARK: - Writing

    func reset() {
        lock.withLock {
            fluxHistory.removeAll()
            intervals.removeAll()
            lastBeatTime = -1
            currentBPM = 0
            currentConfidence = 0
            currentPhase = 0
            beatFlag = false
        }
    }

    /// Feeds one analysis window. `time` is show time in seconds.
    func process(flux: Float, at time: Double) {
        lock.withLock {
            beatFlag = false
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
        lock.withLock { lockedRegisterBeat(at: time) }
    }

    // MARK: - Estimation
    //
    // These assume `lock` is already held.

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
        beatFlag = true
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
        currentBPM = currentBPM == 0 ? estimate : currentBPM * 0.8 + estimate * 0.2

        // Spread of the intervals about their median, relative to the median itself.
        // Scaled by 3 so that a 33% spread — sloppy but still recognisably a pulse —
        // lands at zero confidence rather than somewhere ambiguous.
        let deviation = intervals.reduce(0) { $0 + abs($1 - median) } / Double(intervals.count)
        let spread = min(1, deviation / median * 3)
        let measured = (1 - spread) * min(1, Double(intervals.count) / 8)
        currentConfidence = currentConfidence * 0.7 + measured * 0.3
    }

    private func lockedUpdatePhase(at time: Double) {
        guard currentBPM > 0, lastBeatTime >= 0 else { currentPhase = 0; return }
        let period = 60.0 / currentBPM
        let elapsed = time - lastBeatTime
        currentPhase = (elapsed / period).truncatingRemainder(dividingBy: 1)
        if currentPhase < 0 { currentPhase += 1 }
    }

    private func lockedEnvelope() -> Double {
        guard currentBPM > 0 else { return 0 }
        return pow(1 - currentPhase, 2)
    }
}
