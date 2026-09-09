import Metal
import MetalKit
import simd
import os

/// Uniform block handed to both shader stages.
/// Layout must stay in sync with `LayerUniforms` in Shaders.metal.
struct LayerUniforms {
    var homography: simd_float3x3
    var tint: SIMD4<Float>
    /// intensity, opacity, saturation, contrast
    var params0: SIMD4<Float>
    /// tintAmount, feather, textureAmount, textureScale
    var params1: SIMD4<Float>
    /// patternIndex, blendIndex, showTime, hasCustomTexture
    var params2: SIMD4<Float>
    /// scrollX, scrollY, canvasAspect, unused
    var params3: SIMD4<Float>
}

/// Immutable snapshot of everything needed to draw one frame.
///
/// Built on the main thread and handed to the renderer whole, so the draw loop
/// never reads model state that the UI might be mutating.
struct RenderFrame {
    var layers: [ResolvedLayer] = []
    var background: RGBAColor = .black
    var canvasAspect: Double = 16.0 / 9.0
    var showTime: Double = 0
    var isPlaying: Bool = false
    /// Layer being edited, drawn with handles by the overlay.
    var selectedLayerID: UUID?
}

/// A layer after audio modulation has been folded into its stored values.
struct ResolvedLayer {
    var id: UUID
    var quad: Quad
    var appearance: Appearance
    var content: LayerContent
}

/// Draws the layer stack into an `MTKView`.
///
/// One draw call per layer, blended in order. There is no intermediate render
/// target: blend modes are expressed as pipeline blend factors, which keeps a
/// dozen layers comfortably inside a 60 fps budget on an iPhone.
final class MetalRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let sampler: MTLSamplerState
    private var pipelines: [BlendMode: MTLRenderPipelineState] = [:]
    private let textureStore: TextureStore
    private let log = Logger(subsystem: "app.videomapper", category: "Renderer")

    /// Latest frame to draw. Written from the main thread, read on the draw thread.
    private var frame = RenderFrame()
    private let frameLock = NSLock()

    init?(device: MTLDevice, textureStore: TextureStore) {
        guard let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = queue
        self.textureStore = textureStore

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        // Repeat so tiled overlay textures wrap; source media is sampled inside
        // 0...1 anyway, so this never bleeds across a layer's edges.
        samplerDescriptor.sAddressMode = .repeat
        samplerDescriptor.tAddressMode = .repeat
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
        self.sampler = sampler

        super.init()

        do {
            try buildPipelines()
        } catch {
            log.error("Pipeline creation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func buildPipelines() throws {
        let library = try device.makeDefaultLibrary(bundle: .main)
        let vertexFunction = library.makeFunction(name: "layer_vertex")
        let fragmentFunction = library.makeFunction(name: "layer_fragment")

        for mode in BlendMode.allCases {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = "Layer \(mode.rawValue)"
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            // The subscript is optional in Swift, but slot 0 always exists on a
            // freshly created descriptor.
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            switch mode {
            case .normal:
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            case .add:
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .one
            case .screen:
                // Shader pre-multiplies, so `one` here gives dst + src - dst*src.
                attachment.sourceRGBBlendFactor = .one
                attachment.destinationRGBBlendFactor = .oneMinusSourceColor
            case .multiply:
                attachment.sourceRGBBlendFactor = .destinationColor
                attachment.destinationRGBBlendFactor = .zero
            }
            pipelines[mode] = try device.makeRenderPipelineState(descriptor: descriptor)
        }
    }

    /// Publishes the frame the next draw should use.
    func submit(_ frame: RenderFrame) {
        frameLock.lock()
        self.frame = frame
        frameLock.unlock()
    }

    private func currentFrame() -> RenderFrame {
        frameLock.lock()
        defer { frameLock.unlock() }
        return frame
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let frame = currentFrame()
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColor(
            red: frame.background.red, green: frame.background.green,
            blue: frame.background.blue, alpha: 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        encoder.setFragmentSamplerState(sampler, index: 0)

        for layer in frame.layers {
            guard let pipeline = pipelines[layer.appearance.blendMode],
                  let source = textureStore.sourceTexture(for: layer,
                                                          showTime: frame.showTime,
                                                          isPlaying: frame.isPlaying)
            else { continue }

            var uniforms = makeUniforms(for: layer, frame: frame)
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<LayerUniforms>.stride, index: 0)
            encoder.setFragmentTexture(source, index: 0)
            // Slot 1 must always be bound, even for layers with no overlay image.
            encoder.setFragmentTexture(textureStore.overlayTexture(for: layer) ?? source, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms(for layer: ResolvedLayer, frame: RenderFrame) -> LayerUniforms {
        let appearance = layer.appearance
        let texture = appearance.texture
        let hasCustom = texture.pattern == .custom && textureStore.overlayTexture(for: layer) != nil
        return LayerUniforms(
            homography: Homography.unitSquare(to: layer.quad),
            tint: appearance.tint.simd,
            params0: SIMD4(Float(appearance.intensity), Float(appearance.opacity),
                           Float(appearance.saturation), Float(appearance.contrast)),
            params1: SIMD4(Float(appearance.tintAmount), Float(appearance.feather),
                           Float(texture.amount), Float(texture.scale)),
            params2: SIMD4(texture.pattern.shaderIndex, appearance.blendMode.shaderIndex,
                           Float(frame.showTime), hasCustom ? 1 : 0),
            params3: SIMD4(Float(texture.scrollX), Float(texture.scrollY),
                           Float(frame.canvasAspect), 0))
    }
}
