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
        var t = playback.startOffset + showTime * max(playback.rate, 0.01)
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

    private func syncTransport(showTime: Double, isPlaying: Bool) {
        guard player.currentItem != nil else { return }

        guard isPlaying else {
            if player.rate != 0 { player.pause() }
            return
        }

        guard playback.followsShowClock else {
            if player.rate == 0 { player.play() }
            player.rate = Float(playback.rate)
            return
        }

        let target = targetTime(showTime: showTime)
        let actual = CMTimeGetSeconds(player.currentTime())
        guard actual.isFinite else { return }

        var error = target - actual
        // Near a loop point the raw error is a whole duration out; fold it.
        if playback.loops, duration > 0 {
            if error > duration / 2 { error -= duration }
            if error < -duration / 2 { error += duration }
        }

        if abs(error) > Self.seekThreshold {
            guard !isSeeking else { return }
            isSeeking = true
            let time = CMTime(seconds: target, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                self?.isSeeking = false
                self?.player.rate = Float(self?.playback.rate ?? 1)
            }
            return
        }

        if player.rate == 0 { player.play() }
        let trim = abs(error) < Self.deadband ? 0 : max(-Self.maxRateTrim, min(Self.maxRateTrim, error))
        player.rate = Float(playback.rate * (1 + trim))
    }
}
