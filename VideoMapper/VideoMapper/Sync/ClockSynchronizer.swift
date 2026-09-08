import Foundation

/// Estimates the offset between this device's clock and the host's.
///
/// Both devices report `CACurrentMediaTime()`, which counts from boot — so the raw
/// values are unrelated and an offset is mandatory before any shared timestamp
/// means anything.
///
/// The estimator follows the NTP round-trip method and then keeps the sample with
/// the *lowest* round-trip time from a recent window. On Wi-Fi, delay is asymmetric
/// and bursty; the quickest exchange is the one least distorted by queueing, so
/// picking the minimum beats averaging.
final class ClockSynchronizer {
    private struct Sample {
        let offset: Double
        let roundTrip: Double
        let takenAt: Double
    }

    /// Samples older than this are dropped, so the estimate tracks clock drift.
    private let sampleLifetime: Double = 30
    private let maximumSamples = 12

    private var samples: [Sample] = []
    private var pending: [UUID: Double] = [:]

    /// hostClock - localClock, in seconds.
    private(set) var offset: Double = 0
    /// Round-trip time of the sample currently in use; a rough quality indicator.
    private(set) var roundTrip: Double = 0
    private(set) var isSynchronized = false

    func reset() {
        samples.removeAll()
        pending.removeAll()
        offset = 0
        roundTrip = 0
        isSynchronized = false
    }

    /// Records an outgoing probe.
    func noteProbeSent(id: UUID, at localTime: Double) {
        pending[id] = localTime
        // Bound the table in case replies never arrive.
        if pending.count > 32 {
            let cutoff = localTime - sampleLifetime
            pending = pending.filter { $0.value > cutoff }
        }
    }

    /// Folds a reply into the estimate. `t1` is the host's clock at the moment it
    /// received our probe; `localNow` is our clock as the reply lands.
    func noteReply(id: UUID, hostTime t1: Double, localNow: Double) {
        guard let t0 = pending.removeValue(forKey: id) else { return }
        let roundTrip = localNow - t0
        guard roundTrip >= 0, roundTrip < 2 else { return }
        // Assume the probe took half the round trip to arrive.
        let sample = Sample(offset: t1 - (t0 + roundTrip / 2),
                            roundTrip: roundTrip,
                            takenAt: localNow)
        samples.append(sample)
        prune(now: localNow)
        recompute()
    }

    private func prune(now: Double) {
        samples.removeAll { now - $0.takenAt > sampleLifetime }
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    private func recompute() {
        guard let best = samples.min(by: { $0.roundTrip < $1.roundTrip }) else { return }
        if isSynchronized {
            // Ease toward the new estimate; a hard jump would visibly snap the show.
            offset += (best.offset - offset) * 0.25
        } else {
            offset = best.offset
            isSynchronized = true
        }
        roundTrip = best.roundTrip
    }

    /// Converts a host timestamp into this device's clock.
    func localTime(forHostTime hostTime: Double) -> Double { hostTime - offset }

    /// Converts a local timestamp into the host's clock.
    func hostTime(forLocalTime localTime: Double) -> Double { localTime + offset }

    var hostNow: Double { hostTime(forLocalTime: HostClock.now) }
}
