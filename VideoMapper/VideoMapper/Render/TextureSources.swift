import AVFoundation
import CoreVideo
import Metal
import MetalKit
import QuartzCore
import os

/// Anything that can hand the renderer a texture for the current show time.
protocol TextureSource: AnyObject {
    /// Advances internal state (video decoding, drift correction) and returns the
    /// texture to draw, or nil to skip the layer this frame.
    func texture(showTime: Double, isPlaying: Bool) -> MTLTexture?
}

/// 1x1 white pixel, used by colour layers so solids share the media pipeline.
final class SolidTextureSource: TextureSource {
    private let white: MTLTexture?

    init(device: MTLDevice) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        white = device.makeTexture(descriptor: descriptor)
        var pixel: [UInt8] = [255, 255, 255, 255]
        white?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                       withBytes: &pixel, bytesPerRow: 4)
    }

    func texture(showTime: Double, isPlaying: Bool) -> MTLTexture? { white }
}

/// A still image decoded once and kept resident.
final class ImageTextureSource: TextureSource {
    private var loaded: MTLTexture?

    init(url: URL, device: MTLDevice) {
        let loader = MTKTextureLoader(device: device)
        loaded = try? loader.newTexture(URL: url, options: [
            .SRGB: false,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ])
    }

    func texture(showTime: Double, isPlaying: Bool) -> MTLTexture? { loaded }
}

/// A video clip decoded straight into Metal textures.
///
/// The clip is slaved to the show clock: every frame the source compares the
/// player's position against where the show says it should be and corrects. Small
/// errors are absorbed by nudging the playback rate (inaudible, invisible), large
/// ones by seeking. That is what keeps two phones frame-aligned over a run.
final class VideoTextureSource: TextureSource {
    /// Beyond this error, seek instead of rate-correcting.
    private static let seekThreshold = 0.15
    /// Below this error, leave the rate alone; chasing jitter looks worse than the drift.
    private static let deadband = 0.008
    /// Hard cap on the rate trim so correction never becomes visible.
    private static let maxRateTrim = 0.05

    private let log = Logger(subsystem: "app.videomapper", category: "Video")
    private let player = AVPlayer()
    private let output: AVPlayerItemVideoOutput
    private var textureCache: CVMetalTextureCache?
    /// Held for as long as the texture is in flight; releasing early can free the
    /// backing IOSurface while the GPU is still reading it.
    private var retainedTexture: CVMetalTexture?
    private var duration: Double = 0
    private var isSeeking = false

    var playback: VideoPlayback

    init?(url: URL, playback: VideoPlayback, duration: Double, device: MTLDevice) {
        self.playback = playback
        self.duration = max(0, duration)
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache) == kCVReturnSuccess
        else { return nil }

        let item = AVPlayerItem(url: url)
        item.add(output)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        player.isMuted = playback.volume <= 0
        player.volume = Float(playback.volume)
    }

    deinit {
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func update(playback: VideoPlayback) {
        self.playback = playback
        player.volume = Float(playback.volume)
        player.isMuted = playback.volume <= 0
    }

    /// Where in the clip the show clock says we should be.
    private func targetTime(showTime: Double) -> Double {
        // Rate zero is a deliberate freeze, not a degenerate case: it holds the clip
        // on its start frame so a layer can be used as a still without importing one.
        guard playback.rate > 0 else { return max(playback.startOffset, 0) }
        var t = playback.startOffset + showTime * playback.rate
        if duration > 0 {
            if playback.loops {
                t = t.truncatingRemainder(dividingBy: duration)
                if t < 0 { t += duration }
            } else {
                t = min(max(t, 0), duration)
            }
        }
        return max(t, 0)
    }

    func texture(showTime: Double, isPlaying: Bool) -> MTLTexture? {
        syncTransport(showTime: showTime, isPlaying: isPlaying)

        let itemTime = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: itemTime) || retainedTexture == nil else {
            return currentTexture()
        }
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil),
              let cache = textureCache else { return currentTexture() }

        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return currentTexture() }
        retainedTexture = cvTexture
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func currentTexture() -> MTLTexture? {
        retainedTexture.flatMap { CVMetalTextureGetTexture($0) }
    }

    /// Whether a clip has run out of item and needs a seek to come back round.
    ///
    /// `actionAtItemEnd` is `.pause`, and a player parked on its last frame ignores
    /// both `play()` and a rate write: only a seek restarts it. Nothing else in the
    /// transport notices, because folding the error across the loop seam makes a clip
    /// that has just run out look perfectly in sync — `target` near zero against an
    /// `actual` of a whole duration folds to an error of about nothing — so the drift
    /// corrector sees no reason to act.
    static func hasRunOut(actual: Double, duration: Double, loops: Bool) -> Bool {
        guard loops, duration > 0, actual.isFinite else { return false }
        return actual >= duration - deadband
    }

    /// Where a free-running clip starts its next pass. Show-clock clips get the
    /// position the show asks for instead.
    ///
    /// An offset at or past the end of the file restarts from the beginning rather
    /// than from itself: seeking back to a position that already counts as the end
    /// would run out again on the same frame and never move.
    private var loopRestartPosition: Double {
        let offset = max(playback.startOffset, 0)
        guard duration > 0 else { return offset }
        return Self.hasRunOut(actual: offset, duration: duration, loops: true) ? 0 : offset
    }

    /// Jumps the player to `target`, ignoring the request if a seek is already in
    /// flight — stacking seeks on a drifting clip makes the drift worse, not better.
    private func seekIfNeeded(to target: Double) {
        guard !isSeeking else { return }
        let actual = CMTimeGetSeconds(player.currentTime())
        if actual.isFinite, abs(actual - target) < Self.deadband { return }
        isSeeking = true
        let time = CMTime(seconds: target, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            self.isSeeking = false
            self.player.rate = Float(self.playback.rate)
        }
    }

    private func syncTransport(showTime: Double, isPlaying: Bool) {
        guard player.currentItem != nil else { return }

        guard isPlaying else {
            if player.rate != 0 { player.pause() }
            return
        }

        // A frozen clip is simply paused. Calling play() first would momentarily run
        // it at 1x before the rate assignment lands, which reads as a twitch.
        guard playback.rate > 0 else {
            if player.rate != 0 { player.pause() }
            if playback.followsShowClock { seekIfNeeded(to: targetTime(showTime: showTime)) }
            return
        }

        guard playback.followsShowClock else {
            // A free-running clip has no show clock to pull it back round, so without
            // this it plays once and holds its last frame for the rest of the show.
            if Self.hasRunOut(actual: CMTimeGetSeconds(player.currentTime()),
                              duration: duration, loops: playback.loops) {
                seekIfNeeded(to: loopRestartPosition)
                return
            }
            if player.rate == 0 { player.play() }
            player.rate = Float(playback.rate)
            return
        }

        let target = targetTime(showTime: showTime)
        let actual = CMTimeGetSeconds(player.currentTime())
        guard actual.isFinite else { return }

        // Taken before the fold below, which is what hides this case from the error
        // test: the clip is parked at the end and only a seek will move it.
        if Self.hasRunOut(actual: actual, duration: duration, loops: playback.loops) {
            seekIfNeeded(to: target)
            return
        }

        var error = target - actual
        // Near a loop point the raw error is a whole duration out; fold it.
        if playback.loops, duration > 0 {
            if error > duration / 2 { error -= duration }
            if error < -duration / 2 { error += duration }
        }

        if abs(error) > Self.seekThreshold {
            seekIfNeeded(to: target)
            return
        }

        if player.rate == 0 { player.play() }
        let trim = abs(error) < Self.deadband ? 0 : max(-Self.maxRateTrim, min(Self.maxRateTrim, error))
        player.rate = Float(playback.rate * (1 + trim))
    }
}
