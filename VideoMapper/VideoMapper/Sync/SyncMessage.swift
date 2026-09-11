import Foundation

/// The transport state shared across devices.
///
/// Rather than sending "play now" (which arrives late, and differently late on each
/// device), the host sends an *anchor*: at host-clock time `anchorHostTime` the show
/// was at `showTime`. Every device can then compute the current show time from its
/// own clock, and a late-joining device lands in the right place immediately.
struct TransportSnapshot: Codable, Equatable {
    var isPlaying: Bool = false
    /// Host clock reading, in seconds, for the anchor.
    var anchorHostTime: Double = 0
    /// Show time at the anchor.
    var showTime: Double = 0
    /// Track position at the anchor, so audio can be scheduled to match.
    var trackPosition: Double = 0
    var hasTrack: Bool = false
    /// Identifies the track so a follower can warn when it holds a different file.
    var trackFingerprint: String?

    /// Show time now, given this device's estimate of the host clock.
    func showTime(atHostTime hostNow: Double) -> Double {
        guard isPlaying else { return showTime }
        return showTime + (hostNow - anchorHostTime)
    }
}

/// A single parameter tweak, broadcast while a slider is moving.
///
/// Sending one small message per change keeps live control responsive; the full
/// project is only re-sent on structural edits.
struct ParameterUpdate: Codable, Equatable {
    enum Key: String, Codable {
        case opacity, intensity, tintAmount, saturation, contrast, feather
        case textureAmount, textureScale, visible
    }
    var layerID: UUID
    var key: Key
    var value: Double
}

enum SyncMessage: Codable {
    case hello(name: String, isHost: Bool)
    /// Clock probe. `t0` is the sender's clock when it sent.
    case ping(id: UUID, t0: Double)
    /// Probe reply. `t1` is the host's clock when it received the ping.
    case pong(id: UUID, t0: Double, t1: Double)
    case transport(TransportSnapshot)
    /// Full project as JSON, sent on join and after structural edits.
    case project(Data)
    case parameter(ParameterUpdate)
    /// Host's tempo, so followers animate beat routes identically even when only
    /// the host can hear the music.
    case tempo(bpm: Double, beatHostTime: Double)

    func encoded() throws -> Data { try JSONEncoder().encode(self) }
    static func decode(_ data: Data) throws -> SyncMessage {
        try JSONDecoder().decode(SyncMessage.self, from: data)
    }
}
