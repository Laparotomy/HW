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
    @ObservedObject private var thumbnails = ContentThumbnailStore.shared

    /// Transform captured when a gesture begins, so every update is applied to the
    /// original rather than compounding.
    @State private var gestureStartTransform: LayerTransform?
    @State private var activeCorner: Int?
    /// Index into the mesh's control points while one is being dragged.
    @State private var activeMeshPoint: Int?
    @State private var draggingLayerID: UUID?
    /// Pinch and rotation run simultaneously with the drag, so each keeps its own
    /// starting transform rather than fighting over one.
    @State private var pinchStartTransform: LayerTransform?
    @State private var rotateStartTransform: LayerTransform?

    /// Points the current drag can land on, gathered once when it starts. Gathering
    /// them per frame would walk every layer of the show sixty times a second.
    @State private var snapCandidates: [PointSnapping.Candidate] = []
    /// What the dragged point is currently pulled onto, for the badge.
    @State private var snapTarget: PointSnapping.Target?
    /// Transient note under the stage — why a tap did not add a point, mostly.
    @State private var stageMessage: String?
    @State private var messageTask: Task<Void, Never>?

    private let handleRadius: CGFloat = 13
    /// Above this many points, interior labels are dropped: they would overlap each
    /// other and hide the image underneath, which is the thing being aligned.
    private let labelBudget = 49

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
            .overlay(alignment: .bottom) { messageBar }
        }
        .background(Color.black)
    }

    /// Letterboxes the canvas so what you see matches the projector's aspect ratio.
    private func fittedSize(in available: CGSize) -> CGSize {
        available.fitting(aspect: controller.project.canvasAspect)
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
            referenceUnderlay
            overlay(size: size)
        }
        .contentShape(Rectangle())
        .gesture(dragGesture(size: size))
        .simultaneousGesture(pointGesture(size: size))
        .simultaneousGesture(scaleGesture())
        .simultaneousGesture(rotateGesture())
    }

    /// The scanned surface, ghosted over the stage.
    ///
    /// Over rather than under: the renderer's output is opaque, and making it
    /// transparent to slip a photo behind would change the one code path the
    /// projector also runs. A ghost on top costs nothing and is only ever on screen
    /// while editing.
    @ViewBuilder
    private var referenceUnderlay: some View {
        if controller.referenceOpacity > 0,
           let scan = controller.project.activeScan,
           let image = thumbnails.referenceImage(for: scan, projectID: controller.project.id) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .opacity(controller.referenceOpacity)
                .blendMode(.screen)
                .allowsHitTesting(false)
                .clipped()
        }
    }

    @ViewBuilder
    private var messageBar: some View {
        if let stageMessage {
            Text(stageMessage)
                .font(.caption)
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.black.opacity(0.65)))
                .padding(.bottom, 10)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func show(_ message: String) {
        messageTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { stageMessage = message }
        messageTask = Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { stageMessage = nil }
        }
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
                if layer.transform.mesh.isSubdivided {
                    meshOverlay(layer: layer, size: size)
                } else {
                    ForEach(Array(points.enumerated()), id: \.offset) { index, position in
                        handle(at: position, label: Self.cornerNames[index],
                               isActive: activeCorner == index, isCorner: true)
                    }
                }
                snapBadge(layer: layer, size: size)
            }
        }
    }

    /// Control points plus the cell edges between them, so the correction being
    /// applied is visible rather than guessed at from the image alone.
    @ViewBuilder
    private func meshOverlay(layer: MappingLayer, size: CGSize) -> some View {
        let mesh = layer.transform.mesh
        let points = layer.transform.meshPoints().map { point(for: $0, in: size) }

        Path { path in
            for row in 0...mesh.rows {
                for column in 0...mesh.columns {
                    let index = mesh.index(column: column, row: row)
                    guard points.indices.contains(index) else { continue }
                    if column < mesh.columns, points.indices.contains(index + 1) {
                        path.move(to: points[index])
                        path.addLine(to: points[index + 1])
                    }
                    let below = index + mesh.pointsAcross
                    if row < mesh.rows, points.indices.contains(below) {
                        path.move(to: points[index])
                        path.addLine(to: points[below])
                    }
                }
            }
        }
        .stroke(Color.accentColor.opacity(0.45), lineWidth: 1)
        .allowsHitTesting(false)

        ForEach(Array(points.enumerated()), id: \.offset) { index, position in
            let column = index % mesh.pointsAcross
            let row = index / mesh.pointsAcross
            let isCorner = (column == 0 || column == mesh.columns)
                && (row == 0 || row == mesh.rows)
            handle(at: position,
                   label: label(column: column, row: row, isCorner: isCorner,
                                pointCount: mesh.pointCount, isActive: activeMeshPoint == index),
                   isActive: activeMeshPoint == index,
                   isCorner: isCorner)
        }
    }

    private static let cornerNames = ["TL", "TR", "BR", "BL"]

    /// What a handle is called.
    ///
    /// Corners keep the names an operator would use out loud — "pull the top left in"
    /// — and interior points are numbered by their column and row, which is the only
    /// way to say which of forty identical dots you mean.
    private func label(column: Int, row: Int, isCorner: Bool,
                       pointCount: Int, isActive: Bool) -> String? {
        if isCorner {
            let name = (row == 0 ? "T" : "B") + (column == 0 ? "L" : "R")
            return name
        }
        guard isActive || pointCount <= labelBudget else { return nil }
        return "\(column + 1)·\(row + 1)"
    }

    /// Corners are drawn full size; interior points smaller, so the outline of the
    /// surface stays readable through a dense grid.
    private func handle(at position: CGPoint, label: String?,
                        isActive: Bool, isCorner: Bool) -> some View {
        let radius = isCorner ? handleRadius : handleRadius * 0.62
        // The label rides in an overlay rather than a stack: an overlay does not
        // enlarge what it sits on, so the dot stays centred on the point it marks
        // however wide its name turns out to be.
        return Circle()
            .fill(isActive ? Color.accentColor : Color.white)
            .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            .frame(width: radius * 2, height: radius * 2)
            .overlay {
                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize()
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .offset(y: -(radius + 9))
                }
            }
            .position(position)
            .allowsHitTesting(false)
    }

    /// Says what the point in hand has been pulled onto, because a snap that happens
    /// silently is indistinguishable from a drag that missed.
    @ViewBuilder
    private func snapBadge(layer: MappingLayer, size: CGSize) -> some View {
        if let snapTarget, let index = activeMeshPoint ?? activeCorner {
            let handles = layer.transform.mesh.isSubdivided
                ? layer.transform.meshPoints()
                : layer.transform.quad().corners
            if handles.indices.contains(index) {
                Label(snapTarget.label, systemImage: "magnet")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.yellow))
                    .fixedSize()
                    .position(point(for: handles[index], in: size))
                    .offset(y: 24)
                    .allowsHitTesting(false)
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

    // MARK: - Adding and removing points

    /// A double tap in Warp mode adds a control point where you tapped, or takes one
    /// away if you tapped one that is already there.
    private func pointGesture(size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in editPoint(at: value.location, size: size) }
    }

    private func editPoint(at viewPoint: CGPoint, size: CGSize) {
        guard controller.stageMode == .warp else {
            show("Switch the stage to Warp to add points.")
            return
        }
        guard let layer = controller.selectedLayer, !layer.isLocked else {
            show("This layer is locked.")
            return
        }

        // On top of an existing handle, the tap removes it instead.
        if layer.transform.mesh.isSubdivided {
            let points = layer.transform.meshPoints().map { point(for: $0, in: size) }
            if let nearest = points.enumerated()
                .min(by: { $0.element.distance(to: viewPoint) < $1.element.distance(to: viewPoint) }),
               nearest.element.distance(to: viewPoint) < handleRadius * 1.6 {
                if controller.removeMeshPoint(nearest.offset, inLayer: layer.id) {
                    show("Removed that row and column.")
                } else {
                    show("Corners belong to the layer itself and cannot be removed.")
                }
                return
            }
        }

        let location = normalized(for: viewPoint, in: size)
        if let failure = controller.insertMeshPoint(near: location, inLayer: layer.id) {
            show(failure.message)
        } else {
            show("Point added. It brings its row and column with it.")
        }
    }

    // MARK: - Gestures

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let location = normalized(for: value.location, in: size)

                if gestureStartTransform == nil {
                    beginDrag(at: value.startLocation,
                              normalized: normalized(for: value.startLocation, in: size),
                              size: size)
                }
                guard let id = draggingLayerID, let start = gestureStartTransform else { return }

                let landing = snapped(location, size: size)
                if snapTarget != landing.target { snapTarget = landing.target }

                controller.updateLayer(id: id) { layer in
                    guard !layer.isLocked else { return }
                    if let point = activeMeshPoint {
                        // Same rule as a corner: refuse anything that folds a cell.
                        guard start.meshIsDrawable(movingPointAt: point, to: landing.position) else { return }
                        var transform = start
                        transform.setMeshPoint(point, to: landing.position)
                        layer.transform = transform
                    } else if let corner = activeCorner {
                        var transform = start
                        transform.setCorner(corner, to: landing.position)
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
                activeMeshPoint = nil
                draggingLayerID = nil
                snapCandidates = []
                snapTarget = nil
                controller.saveNow()
            }
    }

    /// Where a dragged point should actually land, once nearby points have had their
    /// say. Only handles snap — dragging a whole layer by its middle has no one point
    /// to line up, and pulling it about would fight the finger.
    private func snapped(_ location: CGPoint,
                         size: CGSize) -> (position: CGPoint, target: PointSnapping.Target?) {
        guard controller.snapsPoints, activeMeshPoint != nil || activeCorner != nil else {
            return (location, nil)
        }
        var candidates = snapCandidates
        candidates += PointSnapping.canvasCandidates(near: location)
        guard let result = PointSnapping.snap(location, to: candidates,
                                              radius: snapRadius(in: size),
                                              aspect: controller.project.canvasAspect) else {
            return (location, nil)
        }
        return (result.position, result.target)
    }

    /// The pull is a fingertip wide on screen, converted into the canvas's own units.
    /// Measured against height because that is the axis `PointSnapping` normalizes to.
    private func snapRadius(in size: CGSize) -> Double {
        guard size.height > 0 else { return PointSnapping.defaultRadius }
        return min(0.08, max(0.006, Double(handleRadius * 1.5 / size.height)))
    }

    /// Decides what the touch grabbed: a corner handle, the selected layer, or
    /// whichever layer is topmost under the finger.
    private func beginDrag(at viewPoint: CGPoint, normalized location: CGPoint, size: CGSize) {
        if controller.stageMode == .warp, let layer = controller.selectedLayer, !layer.isLocked {
            let mesh = layer.transform.mesh
            let handles = mesh.isSubdivided
                ? layer.transform.meshPoints().map { point(for: $0, in: size) }
                : layer.transform.quad().corners.map { point(for: $0, in: size) }
            // Generous hit radius: fingertips are wider than the handles. A dense
            // grid puts points close together, so the radius shrinks with the cell
            // size rather than letting neighbours overlap into each other.
            let spacing: CGFloat = mesh.isSubdivided
                ? min(size.width / CGFloat(mesh.columns), size.height / CGFloat(mesh.rows)) * 0.45
                : .greatestFiniteMagnitude
            let radius = min(handleRadius * 2.2, max(handleRadius, spacing))

            if let nearest = handles.enumerated()
                .min(by: { $0.element.distance(to: viewPoint) < $1.element.distance(to: viewPoint) }),
               nearest.element.distance(to: viewPoint) < radius {
                if mesh.isSubdivided {
                    activeMeshPoint = nearest.offset
                } else {
                    activeCorner = nearest.offset
                }
                draggingLayerID = layer.id
                gestureStartTransform = layer.transform
                snapCandidates = gatherSnapCandidates(for: layer, pointIndex: nearest.offset)
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
            activeMeshPoint = nil
            snapCandidates = []
        }
    }

    private func gatherSnapCandidates(for layer: MappingLayer,
                                      pointIndex: Int) -> [PointSnapping.Candidate] {
        guard controller.snapsPoints else { return [] }
        var candidates = PointSnapping.candidates(in: controller.project.layers,
                                                  excluding: layer.id)
        candidates += PointSnapping.selfCandidates(of: layer.transform, excluding: pointIndex)
        return candidates
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
