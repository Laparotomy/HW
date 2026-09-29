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
///
/// Every stored property is guarded by `lock`. Replies arrive on the Multipeer
/// session's delegate queue while the show reads `offset` every frame on the render
/// thread and `reset` runs on the main thread, so all three touch this object at
/// once during a synchronised show.
final class ClockSynchronizer {
    private struct Sample {
        let offset: Double
        let roundTrip: Double
        let takenAt: Double
    }

    /// A consistent view of the estimate, read under one lock.
    struct Snapshot {
        var offset: Double = 0
        var roundTrip: Double = 0
        var isSynchronized = false
    }

    /// Samples older than this are dropped, so the estimate tracks clock drift.
    private let sampleLifetime: Double = 30
    private let maximumSamples = 12

    /// Guards every stored property below. Not recursive: the `locked` helpers
    /// assume it is already held and must never take it again.
    private let lock = NSLock()

    private var samples: [Sample] = []
    private var pending: [UUID: Double] = [:]

    private var storedOffset: Double = 0
    private var storedRoundTrip: Double = 0
    private var storedIsSynchronized = false

    /// hostClock - localClock, in seconds.
    var offset: Double { withLock { storedOffset } }
    /// Round-trip time of the sample currently in use; a rough quality indicator.
    var roundTrip: Double { withLock { storedRoundTrip } }
    var isSynchronized: Bool { withLock { storedIsSynchronized } }

    /// Offset, round trip and synchronisation state taken in one consistent read.
    func snapshot() -> Snapshot {
        withLock { Snapshot(offset: storedOffset,
                            roundTrip: storedRoundTrip,
                            isSynchronized: storedIsSynchronized) }
    }

    func reset() {
        withLock {
            samples.removeAll()
            pending.removeAll()
            storedOffset = 0
            storedRoundTrip = 0
            storedIsSynchronized = false
        }
    }

    /// Records an outgoing probe.
    func noteProbeSent(id: UUID, at localTime: Double) {
        withLock {
            pending[id] = localTime
            // Bound the table in case replies never arrive.
            if pending.count > 32 {
                let cutoff = localTime - sampleLifetime
                pending = pending.filter { $0.value > cutoff }
            }
        }
    }

    /// Folds a reply into the estimate. `t1` is the host's clock at the moment it
    /// received our probe; `localNow` is our clock as the reply lands.
    func noteReply(id: UUID, hostTime t1: Double, localNow: Double) {
        withLock {
            guard let t0 = pending.removeValue(forKey: id) else { return }
            let roundTrip = localNow - t0
            guard roundTrip >= 0, roundTrip < 2 else { return }
            // Assume the probe took half the round trip to arrive.
            let sample = Sample(offset: t1 - (t0 + roundTrip / 2),
                                roundTrip: roundTrip,
                                takenAt: localNow)
            samples.append(sample)
            lockedPrune(now: localNow)
            lockedRecompute()
        }
    }

    /// Converts a host timestamp into this device's clock.
    func localTime(forHostTime hostTime: Double) -> Double { hostTime - offset }

    /// Converts a local timestamp into the host's clock.
    func hostTime(forLocalTime localTime: Double) -> Double { localTime + offset }

    var hostNow: Double { hostTime(forLocalTime: HostClock.now) }

    // MARK: - Locked internals
    //
    // Each of these assumes `lock` is already held by its caller.

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func lockedPrune(now: Double) {
        samples.removeAll { now - $0.takenAt > sampleLifetime }
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    private func lockedRecompute() {
        guard let best = samples.min(by: { $0.roundTrip < $1.roundTrip }) else { return }
        if storedIsSynchronized {
            // Ease toward the new estimate; a hard jump would visibly snap the show.
            storedOffset += (best.offset - storedOffset) * 0.25
        } else {
            storedOffset = best.offset
            storedIsSynchronized = true
        }
        storedRoundTrip = best.roundTrip
    }
}
