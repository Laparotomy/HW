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
