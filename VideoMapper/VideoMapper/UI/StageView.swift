import MetalKit
import SwiftUI

/// Hosts the `MTKView` and pumps the render loop.
///
/// `MTKView` calls its delegate on the main thread, which is also where the show
/// state lives — so a frame can be built and submitted in the same hop with no
/// copying and no locks in the hot path.
struct MetalStageView: UIViewRepresentable {
    let controller: ShowController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: controller.device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.isOpaque = true
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        private let controller: ShowController

        init(controller: ShowController) {
            self.controller = controller
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            // MTKView drives its delegate from a main-thread display link.
            MainActor.assumeIsolated {
                guard let renderer = controller.renderer else { return }
                renderer.submit(controller.makeFrame())
                renderer.draw(in: view)
            }
        }
    }
}

/// The editing surface: rendered output plus direct-manipulation handles.
struct StageView: View {
    @ObservedObject var controller: ShowController

    /// Transform captured when a gesture begins, so every update is applied to the
    /// original rather than compounding.
    @State private var gestureStartTransform: LayerTransform?
    @State private var activeCorner: Int?
    @State private var draggingLayerID: UUID?
    /// Pinch and rotation run simultaneously with the drag, so each keeps its own
    /// starting transform rather than fighting over one.
    @State private var pinchStartTransform: LayerTransform?
    @State private var rotateStartTransform: LayerTransform?

    private let handleRadius: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let size = fittedSize(in: geometry.size)
            ZStack {
                Color.black
                stage(size: size)
                    .frame(width: size.width, height: size.height)
                    .clipped()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(Color.black)
    }

    /// Letterboxes the canvas so what you see matches the projector's aspect ratio.
    private func fittedSize(in available: CGSize) -> CGSize {
        let aspect = controller.project.canvasAspect
        guard available.width > 0, available.height > 0, aspect > 0 else { return available }
        if available.width / available.height > aspect {
            return CGSize(width: available.height * aspect, height: available.height)
        }
        return CGSize(width: available.width, height: available.width / aspect)
    }

    @ViewBuilder
    private func stage(size: CGSize) -> some View {
        ZStack {
            if controller.renderer != nil {
                MetalStageView(controller: controller)
            } else {
                Text("Rendering is unavailable on this device")
                    .foregroundStyle(.secondary)
            }
            overlay(size: size)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(size: size))
        .simultaneousGesture(scaleGesture())
        .simultaneousGesture(rotateGesture())
    }

    // MARK: - Handles

    @ViewBuilder
    private func overlay(size: CGSize) -> some View {
        if let layer = controller.selectedLayer, layer.isVisible {
            let quad = layer.transform.quad()
            let points = quad.corners.map { point(for: $0, in: size) }

            Path { path in
                path.move(to: points[0])
                for p in points.dropFirst() { path.addLine(to: p) }
                path.closeSubpath()
            }
            .stroke(layer.isLocked ? Color.orange : Color.accentColor,
                    style: StrokeStyle(lineWidth: 1.5, dash: layer.isLocked ? [6, 4] : []))
            .allowsHitTesting(false)

            if controller.stageMode == .warp && !layer.isLocked {
                ForEach(Array(points.enumerated()), id: \.offset) { index, position in
                    Circle()
                        .fill(activeCorner == index ? Color.accentColor : Color.white)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
                        .frame(width: handleRadius * 2, height: handleRadius * 2)
                        .position(position)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func point(for normalized: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func normalized(for point: CGPoint, in size: CGSize) -> CGPoint {
        guard size.width > 0, size.height > 0 else { return .zero }
        return CGPoint(x: point.x / size.width, y: point.y / size.height)
    }

    // MARK: - Gestures

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = normalized(for: value.location, in: size)

                if gestureStartTransform == nil {
                    beginDrag(at: value.startLocation, normalized: normalized(for: value.startLocation, in: size), size: size)
                }
                guard let id = draggingLayerID, let start = gestureStartTransform else { return }

                controller.updateLayer(id: id) { layer in
                    guard !layer.isLocked else { return }
                    if let corner = activeCorner {
                        var transform = start
                        transform.setCorner(corner, to: location)
                        // Refuse a drag that folds the quad; the homography would be
                        // degenerate and the layer would vanish or turn inside out.
                        if transform.quad().isConvex { layer.transform = transform }
                    } else {
                        let startPoint = normalized(for: value.startLocation, in: size)
                        let delta = location - startPoint
                        layer.transform = start
                        layer.transform.center = CGPoint(x: start.center.x + delta.x,
                                                         y: start.center.y + delta.y)
                    }
                }
            }
            .onEnded { _ in
                gestureStartTransform = nil
                activeCorner = nil
                draggingLayerID = nil
                controller.saveNow()
            }
    }

    /// Decides what the touch grabbed: a corner handle, the selected layer, or
    /// whichever layer is topmost under the finger.
    private func beginDrag(at viewPoint: CGPoint, normalized location: CGPoint, size: CGSize) {
        if controller.stageMode == .warp, let layer = controller.selectedLayer, !layer.isLocked {
            let corners = layer.transform.quad().corners.map { point(for: $0, in: size) }
            // Generous hit radius: fingertips are wider than the handles.
            if let nearest = corners.enumerated()
                .min(by: { $0.element.distance(to: viewPoint) < $1.element.distance(to: viewPoint) }),
               nearest.element.distance(to: viewPoint) < handleRadius * 2.2 {
                activeCorner = nearest.offset
                draggingLayerID = layer.id
                gestureStartTransform = layer.transform
                return
            }
        }

        // Topmost first: the layer drawn last is the one you see.
        if let hit = controller.project.layers.last(where: {
            $0.isVisible && !$0.isLocked && $0.transform.quad().contains(location)
        }) {
            controller.selectedLayerID = hit.id
            draggingLayerID = hit.id
            gestureStartTransform = hit.transform
            activeCorner = nil
        }
    }

    private func scaleGesture() -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let magnification = value.magnification
                guard let layer = controller.selectedLayer, !layer.isLocked else { return }
                if pinchStartTransform == nil { pinchStartTransform = layer.transform }
                guard let start = pinchStartTransform else { return }
                controller.updateLayer(id: layer.id) { layer in
                    // Clamped so a stray pinch cannot shrink a layer to nothing.
                    layer.transform.size = CGSize(width: min(4, max(0.02, start.size.width * magnification)),
                                                  height: min(4, max(0.02, start.size.height * magnification)))
                }
            }
            .onEnded { _ in
                pinchStartTransform = nil
                controller.saveNow()
            }
    }

    private func rotateGesture() -> some Gesture {
        RotateGesture()
            .onChanged { value in
                guard let layer = controller.selectedLayer, !layer.isLocked else { return }
                if rotateStartTransform == nil { rotateStartTransform = layer.transform }
                guard let start = rotateStartTransform else { return }
                controller.updateLayer(id: layer.id) { layer in
                    layer.transform.rotation = start.rotation + value.rotation.radians
                }
            }
            .onEnded { _ in
                rotateStartTransform = nil
                controller.saveNow()
            }
    }
}
