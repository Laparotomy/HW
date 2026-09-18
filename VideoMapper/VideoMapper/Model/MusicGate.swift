import Foundation

/// Decides whether the show should be moving, when it is set to animate only while
/// music plays.
///
/// Pulled out of `ShowController` so it can be reasoned about on its own. The failure
/// mode here is a show that never starts — a frozen stage with no error anywhere to
/// say why — and that is exactly the kind of thing worth being able to test without a
/// GPU, an audio engine and a running app around it.
struct MusicGate {
    /// How long the show keeps moving after the level drops below the threshold.
    var hold: Double

    /// Last moment something was heard above the threshold. Starts far enough in the
    /// past that a gate which has never heard anything reads as silent rather than as
    /// having just gone quiet.
    private var lastAudible: Double = -.greatestFiniteMagnitude

    init(hold: Double = AudioSettings.musicGateHold) {
        self.hold = hold
    }

    /// Feeds the analyser's current level in. Called once per frame.
    mutating func observe(level: Double, threshold: Double, at time: Double) {
        if level > threshold { lastAudible = time }
    }

    /// True while the hold from the last thing heard has not run out.
    func heardRecently(at time: Double) -> Bool {
        time - lastAudible < hold
    }

    /// Whether music is sounding right now.
    ///
    /// A loaded track answers from the transport, which is exact. Everything else has
    /// to answer from the microphone, where "is music playing" is really "is this room
    /// louder than its own floor" — hence the threshold the operator sets by eye, and
    /// the hold, so a break between two phrases is not a break in the show.
    func isSounding(clock: ClockSource, hasTrack: Bool, trackIsPlaying: Bool,
                    at time: Double) -> Bool {
        switch clock {
        // Free run has no music to wait for and its analyser is not even running, so
        // gating here could only ever freeze the show for good.
        case .freeRun: return true
        case .track: return hasTrack ? trackIsPlaying : heardRecently(at: time)
        case .listen: return heardRecently(at: time)
        }
    }

    /// Forgets what it heard, so a gate reused for a new show does not inherit the
    /// last one's silence.
    mutating func reset() {
        lastAudible = -.greatestFiniteMagnitude
    }
}
