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
/// **Three threads reach this.** Replies land on Multipeer's queue, probes are sent
/// from both that queue and the main run loop's timer, and `reset()` plus every
/// `hostNow` read come from the main thread. One lock guards all of it.
///
/// `generation` is what makes a teardown stick. A reply already in flight when the
/// session is torn down would otherwise fold itself in afterwards and leave a
/// follower believing it is synchronised to a host it is no longer connected to —
/// so `reset()` moves the generation on, and a reading taken before that is no
/// longer `isCurrent`.
/// Safe to share: every field is guarded by `lock`, which is what the
/// `@unchecked` here is asserting.
final class ClockSynchronizer: @unchecked Sendable {
    /// One consistent reading of the estimate.
    struct Reading: Equatable {
        var offset: Double = 0
        var roundTrip: Double = 0
        var isSynchronized = false
        /// Which run of the estimator this came from. See `isCurrent(_:)`.
        var generation: Int = 0
    }

    private struct Sample {
        let offset: Double
        let roundTrip: Double
        let takenAt: Double
    }

    /// Samples older than this are dropped, so the estimate tracks clock drift.
    private let sampleLifetime: Double = 30
    private let maximumSamples = 12

    private let lock = NSLock()

    // Everything below is guarded by `lock`.
    private var samples: [Sample] = []
    private var pending: [UUID: Double] = [:]
    private var currentOffset: Double = 0
    private var currentRoundTrip: Double = 0
    private var synchronized = false
    private var currentGeneration = 0

    // MARK: - Reading

    /// Offset, round trip and synchronisation state as of one instant. Prefer this
    /// over the individual properties when more than one is used together, and when
    /// the values will outlive the call — a `Reading` can be checked against
    /// `isCurrent(_:)` later, three separate reads cannot.
    func snapshot() -> Reading {
        lock.withLock {
            Reading(offset: currentOffset, roundTrip: currentRoundTrip,
                    isSynchronized: synchronized, generation: currentGeneration)
        }
    }

    /// False once `reset()` has moved past the run `reading` came from.
    func isCurrent(_ reading: Reading) -> Bool {
        lock.withLock { reading.generation == currentGeneration }
    }

    /// hostClock - localClock, in seconds.
    var offset: Double { lock.withLock { currentOffset } }

    /// Round-trip time of the sample currently in use; a rough quality indicator.
    var roundTrip: Double { lock.withLock { currentRoundTrip } }

    var isSynchronized: Bool { lock.withLock { synchronized } }

    var generation: Int { lock.withLock { currentGeneration } }

    // MARK: - Writing

    func reset() {
        lock.withLock {
            samples.removeAll()
            pending.removeAll()
            currentOffset = 0
            currentRoundTrip = 0
            synchronized = false
            // Any reply still in flight belongs to the run that just ended.
            currentGeneration += 1
        }
    }

    /// Records an outgoing probe.
    func noteProbeSent(id: UUID, at localTime: Double) {
        lock.withLock {
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
    ///
    /// A reply whose probe was discarded by `reset()` finds nothing pending and is
    /// dropped, which is what stops a torn-down session from being revived by its
    /// own last exchange.
    func noteReply(id: UUID, hostTime t1: Double, localNow: Double) {
        lock.withLock { lockedNoteReply(id: id, hostTime: t1, localNow: localNow) }
    }

    // MARK: - Estimation
    //
    // These assume `lock` is already held.

    private func lockedNoteReply(id: UUID, hostTime t1: Double, localNow: Double) {
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

    private func lockedPrune(now: Double) {
        samples.removeAll { now - $0.takenAt > sampleLifetime }
        if samples.count > maximumSamples {
            samples.removeFirst(samples.count - maximumSamples)
        }
    }

    private func lockedRecompute() {
        guard let best = samples.min(by: { $0.roundTrip < $1.roundTrip }) else { return }
        if synchronized {
            // Ease toward the new estimate; a hard jump would visibly snap the show.
            currentOffset += (best.offset - currentOffset) * 0.25
        } else {
            currentOffset = best.offset
            synchronized = true
        }
        currentRoundTrip = best.roundTrip
    }

    // MARK: - Conversion

    /// Converts a host timestamp into this device's clock.
    func localTime(forHostTime hostTime: Double) -> Double { hostTime - offset }

    /// Converts a local timestamp into the host's clock.
    func hostTime(forLocalTime localTime: Double) -> Double { localTime + offset }

    var hostNow: Double { hostTime(forLocalTime: HostClock.now) }
}
