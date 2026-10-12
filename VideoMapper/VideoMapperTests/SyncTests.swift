import XCTest
@testable import VideoMapper

final class ClockSynchronizerTests: XCTestCase {

    /// Simulates a probe exchange with a known clock offset and symmetric delay.
    /// The estimator should recover the offset almost exactly.
    func testRecoversOffsetWithSymmetricDelay() {
        let sync = ClockSynchronizer()
        let trueOffset = 12.345      // host clock minus local clock
        let oneWayDelay = 0.010

        var localNow = 100.0
        for _ in 0..<6 {
            let id = UUID()
            sync.noteProbeSent(id: id, at: localNow)
            let hostReceive = localNow + oneWayDelay + trueOffset
            localNow += oneWayDelay * 2
            sync.noteReply(id: id, hostTime: hostReceive, localNow: localNow)
            localNow += 1
        }

        XCTAssertTrue(sync.isSynchronized)
        XCTAssertEqual(sync.offset, trueOffset, accuracy: 0.001)
        XCTAssertEqual(sync.roundTrip, oneWayDelay * 2, accuracy: 0.001)
    }

    /// Wi-Fi delivers occasional very slow round trips. Keeping the fastest sample
    /// should stop one bad exchange from dragging the estimate off.
    func testRejectsSlowOutliers() {
        let sync = ClockSynchronizer()
        let trueOffset = 5.0

        func exchange(at localSend: Double, delay: Double, asymmetry: Double = 0) {
            let id = UUID()
            sync.noteProbeSent(id: id, at: localSend)
            let hostReceive = localSend + delay / 2 + asymmetry + trueOffset
            sync.noteReply(id: id, hostTime: hostReceive, localNow: localSend + delay)
        }

        exchange(at: 10, delay: 0.008)
        for i in 1...4 {
            // Badly asymmetric slow probes: these would skew a naive average.
            exchange(at: 10 + Double(i), delay: 0.400, asymmetry: 0.180)
        }

        XCTAssertEqual(sync.offset, trueOffset, accuracy: 0.005)
        XCTAssertLessThan(sync.roundTrip, 0.05)
    }

    func testIgnoresRepliesWithNoMatchingProbe() {
        let sync = ClockSynchronizer()
        sync.noteReply(id: UUID(), hostTime: 999, localNow: 1)
        XCTAssertFalse(sync.isSynchronized)
        XCTAssertEqual(sync.offset, 0)
    }

    func testConversionsAreInverses() {
        let sync = ClockSynchronizer()
        let id = UUID()
        sync.noteProbeSent(id: id, at: 50)
        sync.noteReply(id: id, hostTime: 53, localNow: 50.02)
        let local = 123.456
        XCTAssertEqual(sync.localTime(forHostTime: sync.hostTime(forLocalTime: local)),
                       local, accuracy: 1e-9)
    }
}

final class TransportSnapshotTests: XCTestCase {

    /// The anchor is what makes a late joiner land in the right place: show time is
    /// derived from the host's clock, not from when the message happened to arrive.
    func testShowTimeAdvancesWithHostClock() {
        let snapshot = TransportSnapshot(isPlaying: true, anchorHostTime: 1000,
                                         showTime: 4, trackPosition: 4, hasTrack: true,
                                         trackFingerprint: "track|1000")
        XCTAssertEqual(snapshot.showTime(atHostTime: 1000), 4, accuracy: 1e-9)
        XCTAssertEqual(snapshot.showTime(atHostTime: 1002.5), 6.5, accuracy: 1e-9)
    }

    func testPausedShowTimeIsFrozen() {
        let snapshot = TransportSnapshot(isPlaying: false, anchorHostTime: 1000, showTime: 4)
        XCTAssertEqual(snapshot.showTime(atHostTime: 1030), 4, accuracy: 1e-9)
    }

    /// Two devices with different boot times must agree on show time once each has
    /// its own offset estimate.
    func testDevicesAgreeAfterOffsetCorrection() {
        let snapshot = TransportSnapshot(isPlaying: true, anchorHostTime: 500, showTime: 10)

        let deviceA = ClockSynchronizer()   // offset +40 s from host
        let idA = UUID()
        deviceA.noteProbeSent(id: idA, at: 100)
        deviceA.noteReply(id: idA, hostTime: 140.005, localNow: 100.01)

        let deviceB = ClockSynchronizer()   // offset -7 s from host
        let idB = UUID()
        deviceB.noteProbeSent(id: idB, at: 900)
        deviceB.noteReply(id: idB, hostTime: 893.004, localNow: 900.008)

        XCTAssertEqual(deviceA.offset, 40, accuracy: 1e-6)
        XCTAssertEqual(deviceB.offset, -7, accuracy: 1e-6)

        // One real instant, at which the host's clock reads 512. Each device's own
        // clock reads something completely different.
        let hostInstant = 512.0
        let localReadingA = hostInstant - 40    // device A booted 40 s after the host
        let localReadingB = hostInstant + 7     // device B booted 7 s before it

        let timeA = snapshot.showTime(atHostTime: deviceA.hostTime(forLocalTime: localReadingA))
        let timeB = snapshot.showTime(atHostTime: deviceB.hostTime(forLocalTime: localReadingB))
        XCTAssertEqual(timeA, 22, accuracy: 1e-6)
        XCTAssertEqual(timeB, 22, accuracy: 1e-6)
    }
}

final class SyncMessageTests: XCTestCase {
    func testRoundTripsThroughJSON() throws {
        let messages: [SyncMessage] = [
            .hello(name: "Stage Left", isHost: true),
            .ping(id: UUID(), t0: 12.5),
            .pong(id: UUID(), t0: 12.5, t1: 900.25),
            .transport(TransportSnapshot(isPlaying: true, anchorHostTime: 1, showTime: 2,
                                         trackPosition: 3, hasTrack: true, trackFingerprint: "a|1")),
            .parameter(ParameterUpdate(layerID: UUID(), key: .intensity, value: 1.75)),
            .tempo(bpm: 128, beatHostTime: 42)
        ]
        for message in messages {
            let decoded = try SyncMessage.decode(try message.encoded())
            switch (message, decoded) {
            case (.transport(let a), .transport(let b)):
                XCTAssertEqual(a, b)
            case (.parameter(let a), .parameter(let b)):
                XCTAssertEqual(a, b)
            case (.hello, .hello), (.ping, .ping), (.pong, .pong), (.tempo, .tempo):
                break
            default:
                XCTFail("message changed case in transit")
            }
        }
    }
}

/// `SyncSession` folds a reply in on Multipeer's queue and then publishes the result
/// on the main queue. A reply already in flight when the role changes lands *after*
/// `teardown()` has reset the clock and zeroed the published values, so without a
/// guard it puts the old offset back and the UI claims a lock on a host the device
/// is no longer talking to. These cover the two things that stop it: `reset()` moves
/// the generation on, and it drops the pending probes a late reply would match.
final class ClockGenerationTests: XCTestCase {

    /// Drives one full exchange and returns the id used, so a test can replay it.
    private func exchange(_ sync: ClockSynchronizer, at localSend: Double,
                          offset: Double, delay: Double = 0.01) {
        let id = UUID()
        sync.noteProbeSent(id: id, at: localSend)
        sync.noteReply(id: id, hostTime: localSend + delay / 2 + offset,
                       localNow: localSend + delay)
    }

    func testAFreshEstimatorIsAtGenerationZero() {
        XCTAssertEqual(ClockSynchronizer().snapshot().generation, 0)
    }

    func testResetMovesTheGenerationOn() {
        let sync = ClockSynchronizer()
        for i in 0..<6 { exchange(sync, at: 100 + Double(i), offset: 12) }

        let beforeReset = sync.snapshot()
        XCTAssertTrue(beforeReset.isSynchronized)
        XCTAssertTrue(sync.isCurrent(beforeReset))

        sync.reset()

        // This is the reading an in-flight reply would carry. It must no longer
        // count as current, or it would be published over the zeroed state.
        XCTAssertFalse(sync.isCurrent(beforeReset))
        XCTAssertTrue(sync.isCurrent(sync.snapshot()))
        XCTAssertEqual(sync.snapshot().generation, beforeReset.generation + 1)
    }

    func testEachResetMovesItOnAgain() {
        let sync = ClockSynchronizer()
        let start = sync.snapshot().generation
        for count in 1...4 {
            sync.reset()
            XCTAssertEqual(sync.snapshot().generation, start + count)
        }
    }

    /// The other half of the fix: a reply that arrives after the teardown finds no
    /// matching probe, so it cannot revive the estimate in the first place.
    func testAReplyWhoseProbeWasDiscardedByResetIsIgnored() {
        let sync = ClockSynchronizer()
        let id = UUID()
        sync.noteProbeSent(id: id, at: 100)

        sync.reset()
        sync.noteReply(id: id, hostTime: 112.005, localNow: 100.01)

        XCTAssertFalse(sync.isSynchronized)
        XCTAssertEqual(sync.offset, 0)
        XCTAssertEqual(sync.roundTrip, 0)
    }

    func testResetClearsTheEstimate() {
        let sync = ClockSynchronizer()
        for i in 0..<6 { exchange(sync, at: 100 + Double(i), offset: -3) }
        XCTAssertTrue(sync.isSynchronized)

        sync.reset()

        XCTAssertFalse(sync.isSynchronized)
        XCTAssertEqual(sync.offset, 0)
        XCTAssertEqual(sync.roundTrip, 0)
        XCTAssertEqual(sync.hostTime(forLocalTime: 7), 7)
    }

    func testASnapshotMatchesTheIndividualReads() {
        let sync = ClockSynchronizer()
        for i in 0..<6 { exchange(sync, at: 200 + Double(i), offset: 4.5) }

        let reading = sync.snapshot()
        XCTAssertEqual(reading.offset, sync.offset)
        XCTAssertEqual(reading.roundTrip, sync.roundTrip)
        XCTAssertEqual(reading.isSynchronized, sync.isSynchronized)
        XCTAssertEqual(reading.generation, sync.generation)
    }

    /// Probes go out from two threads, replies land on a third and the main thread
    /// resets and reads `hostNow`. Before the lock this was `samples` and `pending`
    /// mutated concurrently; the test fails by trapping.
    func testConcurrentExchangesAndResetsStaySound() {
        let sync = ClockSynchronizer()
        let iterations = 400
        let group = DispatchGroup()

        DispatchQueue.global().async(group: group) {
            // Inlined rather than calling the helper, so the closure captures only
            // the estimator and not the test case.
            for i in 0..<iterations {
                let sent = 1000 + Double(i) * 0.1
                let id = UUID()
                sync.noteProbeSent(id: id, at: sent)
                sync.noteReply(id: id, hostTime: sent + 0.005 + 8, localNow: sent + 0.01)
            }
        }
        DispatchQueue.global().async(group: group) {
            for i in 0..<iterations {
                sync.noteProbeSent(id: UUID(), at: 2000 + Double(i) * 0.1)
            }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<iterations { sync.reset() }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<iterations {
                let reading = sync.snapshot()
                // Whatever a reader sees, the parts of it must belong together.
                if !reading.isSynchronized {
                    XCTAssertEqual(reading.offset, 0)
                    XCTAssertEqual(reading.roundTrip, 0)
                }
                _ = sync.hostNow
            }
        }

        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)
        let final = sync.snapshot()
        XCTAssertGreaterThanOrEqual(final.roundTrip, 0)
        XCTAssertTrue(sync.isCurrent(final))
    }
}
