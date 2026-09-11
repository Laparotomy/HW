import CoreGraphics
import Foundation
import Metal
import simd
import os

/// Renders still previews of the generator library.
///
/// The previews come out of the *same* fragment shader the stage uses, so what the
/// browser shows is what the projector will draw — a hand-drawn icon set would drift
/// away from the shaders the first time one is tweaked. They are stills rather than
/// twelve live `MTKView`s because twelve simultaneous Metal layers is a lot of
/// display budget to spend on a picker.
@MainActor
final class GeneratorThumbnailRenderer {
    static let shared = GeneratorThumbnailRenderer()

    /// Small enough that all twelve render in a single command buffer in well under
    /// a frame, large enough to read the pattern on a phone.
    private static let size = (width: 240, height: 135)
    /// Frozen at a show time where every generator has developed some structure;
    /// time zero leaves several of them a flat field.
    private static let previewTime: Double = 7.5

    private let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private let pipeline: MTLRenderPipelineState?
    private let sampler: MTLSamplerState?
    private let white: MTLTexture?
    private let log = Logger(subsystem: "app.videomapper", category: "Thumbnails")

    private var cache: [GeneratorKind: CGImage] = [:]

    private init() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            self.device = nil; self.queue = nil; self.pipeline = nil
            self.sampler = nil; self.white = nil
            return
        }
        self.device = device
        self.queue = queue

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: samplerDescriptor)

        // The shader samples slot 0 even for generators (the result is discarded),
        // so a bound texture is still required.
        let whiteDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 1, height: 1, mipmapped: false)
        whiteDescriptor.usage = .shaderRead
        let whiteTexture = device.makeTexture(descriptor: whiteDescriptor)
        var pixel: [UInt8] = [255, 255, 255, 255]
        whiteTexture?.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                              withBytes: &pixel, bytesPerRow: 4)
        white = whiteTexture

        var built: MTLRenderPipelineState?
        do {
            let library = try device.makeDefaultLibrary(bundle: .main)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Generator thumbnail"
            descriptor.vertexFunction = library.makeFunction(name: "layer_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "layer_fragment")
            descriptor.colorAttachments[0]!.pixelFormat = .bgra8Unorm
            built = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            log.error("Thumbnail pipeline failed: \(error.localizedDescription, privacy: .public)")
        }
        pipeline = built
    }

    /// Returns a preview of `kind` with its default settings, rendering it once and
    /// keeping it for the life of the process.
    func image(for kind: GeneratorKind) -> CGImage? {
        if let cached = cache[kind] { return cached }
        guard let image = render(kind) else { return nil }
        cache[kind] = image
        return image
    }

    private func render(_ kind: GeneratorKind) -> CGImage? {
        guard let device, let queue, let pipeline, let sampler, let white else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: Self.size.width, height: Self.size.height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        // Read back on the CPU, so the contents must be visible to it.
        descriptor.storageMode = .shared
        guard let target = device.makeTexture(descriptor: descriptor),
              let commandBuffer = queue.makeCommandBuffer() else { return nil }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        var uniforms = Self.uniforms(for: kind)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setFragmentTexture(white, index: 0)
        encoder.setFragmentTexture(white, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        return Self.makeImage(from: target)
    }

    /// A full-bleed quad with the generator's default look, at the preview time.
    private static func uniforms(for kind: GeneratorKind) -> LayerUniforms {
        let settings = kind.defaultSettings.clamped()
        let aspect = Double(size.width) / Double(size.height)
        // A strobe caught mid-decay is a black rectangle; show it lit instead.
        let drive: Float = kind == .strobe ? 0.85 : 0.35
        return LayerUniforms(
            homography: Homography.unitSquare(to: Quad.unit),
            tint: RGBAColor.white.simd,
            params0: SIMD4(1, 1, 1, 1),
            params1: SIMD4(0, 0, 0, 8),
            params2: SIMD4(0, BlendMode.normal.shaderIndex, Float(previewTime), 0),
            params3: SIMD4(0, 0, Float(aspect), 0),
            params4: SIMD4(kind.shaderIndex, Float(settings.speed),
                           Float(settings.scale), Float(settings.complexity)),
            params5: SIMD4(settings.palette.shaderIndex, drive, Float(settings.variation), 0))
    }

    private static func makeImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width, height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            texture.getBytes(base, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        // The texture is BGRA; CoreGraphics reads it as such via the byte-order flag.
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            .union(.byteOrder32Little)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
