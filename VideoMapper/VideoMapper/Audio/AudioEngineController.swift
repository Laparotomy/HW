import AVFoundation
import Combine
import QuartzCore
import Foundation
import os

/// Smoothed audio features published to the UI and the modulation engine.
struct AudioFeatures: Equatable {
    var level: Double = 0
    var bass: Double = 0
    var mid: Double = 0
    var treble: Double = 0
    /// Decaying envelope that peaks on each detected beat.
    var beat: Double = 0
    var bpm: Double = 0

    func value(for source: ModulationSource) -> Double {
        switch source {
        case .none: return 0
        case .level: return level
        case .bass: return bass
        case .mid: return mid
        case .treble: return treble
        case .beat: return beat
        }
    }
}

/// Mach-time helpers. `CACurrentMediaTime()` and `AVAudioTime` host time share the
/// same base, which is what lets a network timestamp turn into a sample-accurate
/// start time for the audio engine.
enum HostClock {
    static var now: Double { CACurrentMediaTime() }
    static func hostTime(forSeconds seconds: Double) -> UInt64 {
        AVAudioTime.hostTime(forSeconds: seconds)
    }
    static func seconds(forHostTime hostTime: UInt64) -> Double {
        AVAudioTime.seconds(forHostTime: hostTime)
    }
}

/// Music playback plus analysis.
///
/// Playback can be scheduled against an absolute host time, which is how several
/// devices start the same track together: the host picks a moment slightly in the
/// future, every device converts it into its own clock, and the audio engines all
/// begin on the same sample.
final class AudioEngineController: ObservableObject {
    enum InputMode: String { case track, listen }

    @Published private(set) var features = AudioFeatures()
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var trackTitle: String?
    @Published private(set) var isListening = false
    @Published private(set) var lastError: String?

    let beats = BeatTracker()

    private let log = Logger(subsystem: "app.videomapper", category: "Audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let analyzer = SpectrumAnalyzer()

    private var file: AVAudioFile?
    /// Track position that lines up with the scheduled start.
    private var startPosition: Double = 0
    private var loops = true
    private var tappedNode: AVAudioNode?
    private var analysisTime: Double = 0

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
    }

    // MARK: - Session

    func configureSession(listening: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            if listening {
                // `mixWithOthers` matters: it lets the app listen to (and play over)
                // music coming from another app or a nearby PA without ducking it.
                try session.setCategory(.playAndRecord, mode: .default,
                                        options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers])
            } else {
                try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            }
            try session.setActive(true)
        } catch {
            log.error("Audio session failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Audio session unavailable: \(error.localizedDescription)"
        }
    }

    // MARK: - Track

    func load(url: URL, title: String) {
        stop()
        do {
            let file = try AVAudioFile(forReading: url)
            self.file = file
            duration = Double(file.length) / file.processingFormat.sampleRate
            trackTitle = title
            lastError = nil
        } catch {
            log.error("Could not open track: \(error.localizedDescription, privacy: .public)")
            lastError = "Could not open track: \(error.localizedDescription)"
            file = nil
            duration = 0
            trackTitle = nil
        }
    }

    func unloadTrack() {
        stop()
        file = nil
        duration = 0
        trackTitle = nil
    }

    var hasTrack: Bool { file != nil }

    /// Current position in the track, in seconds.
    ///
    /// Derived from the render clock rather than a timer, so it stays exact over a
    /// long set. Before a scheduled start this is negative, which callers use as a
    /// countdown.
    var trackPosition: Double {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime),
              playerTime.sampleRate > 0 else { return startPosition }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        let position = startPosition + elapsed
        if loops, duration > 0, position > 0 {
            return position.truncatingRemainder(dividingBy: duration)
        }
        return position
    }

    /// Starts playback, optionally at an absolute host time shared across devices.
    func play(from position: Double = 0, atHostTime hostTime: UInt64? = nil, loops: Bool = true, volume: Double = 1) {
        guard let file else { return }
        self.loops = loops
        player.stop()

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, position) * sampleRate)
        guard startFrame < file.length else { return }
        let frameCount = AVAudioFrameCount(file.length - startFrame)

        startPosition = max(0, position)
        engine.mainMixerNode.outputVolume = Float(volume)

        player.scheduleSegment(file, startingFrame: startFrame, frameCount: frameCount,
                               at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.handleSegmentFinished()
        }

        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
        } catch {
            log.error("Engine start failed: \(error.localizedDescription, privacy: .public)")
            lastError = "Audio engine failed to start: \(error.localizedDescription)"
            return
        }

        installAnalysisTap(on: engine.mainMixerNode)

        if let hostTime {
            player.play(at: AVAudioTime(hostTime: hostTime))
        } else {
            player.play()
        }
        setPlaying(true)
    }

    func stop() {
        player.stop()
        startPosition = 0
        setPlaying(false)
    }

    func pause() {
        // Freeze at the current position so a later resume lines up.
        let position = trackPosition
        player.stop()
        startPosition = max(0, position)
        setPlaying(false)
    }

    func setVolume(_ volume: Double) {
        engine.mainMixerNode.outputVolume = Float(max(0, min(1, volume)))
    }

    private func handleSegmentFinished() {
        guard loops, isPlaying, let file else {
            DispatchQueue.main.async { [weak self] in self?.setPlaying(false) }
            return
        }
        // Append the next pass so looping does not leave a gap at the seam.
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            self?.handleSegmentFinished()
        }
    }

    private func setPlaying(_ playing: Bool) {
        if Thread.isMainThread {
            isPlaying = playing
        } else {
            DispatchQueue.main.async { [weak self] in self?.isPlaying = playing }
        }
    }

    // MARK: - Listen mode

    /// Analyses the microphone instead of the loaded track, so the show can lock to
    /// music playing from a system this app has no digital connection to.
    func startListening() async {
        guard await requestRecordPermission() else {
            await MainActor.run { self.lastError = "Microphone access is needed for Listen mode." }
            return
        }
        await MainActor.run {
            self.configureSession(listening: true)
            let input = self.engine.inputNode
            do {
                if !self.engine.isRunning {
                    self.engine.prepare()
                    try self.engine.start()
                }
                self.installAnalysisTap(on: input)
                self.isListening = true
                self.beats.reset()
            } catch {
                self.log.error("Listen mode failed: \(error.localizedDescription, privacy: .public)")
                self.lastError = "Listen mode failed: \(error.localizedDescription)"
            }
        }
    }

    func stopListening() {
        isListening = false
        removeTap()
        configureSession(listening: false)
        if isPlaying { installAnalysisTap(on: engine.mainMixerNode) }
    }

    private func requestRecordPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { continuation.resume(returning: $0) }
            }
        }
    }

    // MARK: - Analysis

    private func installAnalysisTap(on node: AVAudioNode) {
        if tappedNode === node { return }
        removeTap()
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.analyse(buffer: buffer, sampleRate: format.sampleRate)
        }
        tappedNode = node
    }

    private func removeTap() {
        tappedNode?.removeTap(onBus: 0)
        tappedNode = nil
    }

    private func analyse(buffer: AVAudioPCMBuffer, sampleRate: Double) {
        guard let spectrum = analyzer.process(buffer: buffer, sampleRate: sampleRate) else { return }
        // One hop of samples has elapsed since the last window.
        analysisTime += 1024 / sampleRate
        beats.process(flux: spectrum.flux, at: analysisTime)
        let bpm = beats.bpm
        let beat = beats.beatEnvelope

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Fast attack, slow release: peaks read instantly, decay stays smooth.
            func follow(_ current: Double, _ target: Double) -> Double {
                target > current ? target : current * 0.82 + target * 0.18
            }
            var next = AudioFeatures()
            next.level = follow(self.features.level, Double(spectrum.level))
            next.bass = follow(self.features.bass, Double(spectrum.bass))
            next.mid = follow(self.features.mid, Double(spectrum.mid))
            next.treble = follow(self.features.treble, Double(spectrum.treble))
            next.beat = beat
            next.bpm = bpm
            self.features = next
        }
    }

    /// Registers a manual tap-tempo hit.
    func tapTempo() {
        beats.tap(at: analysisTime)
    }
}
