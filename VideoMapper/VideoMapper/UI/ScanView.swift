import ARKit
import SwiftUI

/// Live camera view backed by the scanner's AR session.
struct ARPreview: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session
        // No SceneKit content is added, so the renderer only has to draw the camera
        // feed. Statistics and lighting would be pure overhead.
        view.automaticallyUpdatesLighting = false
        view.rendersContinuously = true
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {}

    static func dismantleUIView(_ view: ARSCNView, coordinator: ()) {
        view.session.pause()
    }
}

/// Capturing a surface.
///
/// The instruction that matters is the one about where to stand, so it is the one
/// on screen the whole time rather than a tip behind an info button: the capture is
/// only useful if the phone is where the projector is.
struct ScanView: View {
    @ObservedObject var controller: ShowController
    @StateObject private var scanner = SurfaceScanner()
    @Environment(\.dismiss) private var dismiss

    @State private var error: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                if scanner.capability == .unsupported {
                    unsupportedView
                } else {
                    ARPreview(session: scanner.session)
                        .ignoresSafeArea()
                    overlay
                }
            }
            .navigationTitle("Scan surface")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Scan failed", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) { error = nil }
            } message: {
                Text(error ?? "")
            }
            .onAppear { scanner.start() }
            .onDisappear { scanner.stop() }
        }
    }

    private var unsupportedView: some View {
        ContentUnavailableView("Scanning is not available",
                               systemImage: "camera.metering.unknown",
                               description: Text(scanner.capability.detail))
    }

    private var overlay: some View {
        VStack {
            instructions
            Spacer()
            captureButton
        }
        .padding()
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(scanner.capability.headline,
                  systemImage: scanner.capability == .depth ? "cube.transparent" : "camera")
                .font(.subheadline.weight(.semibold))

            Text("Hold the phone where the projector's lens is, aimed the way the "
                 + "projector is aimed, and capture. The further the phone is from "
                 + "that spot, the more you will have to fix by hand afterwards.")
                .font(.caption)

            if scanner.capability == .depth {
                HStack(spacing: 8) {
                    Text("Depth coverage")
                    ProgressView(value: scanner.depthCoverage)
                        .tint(scanner.depthCoverage > 0.5 ? .green : .orange)
                    Text("\(Int(scanner.depthCoverage * 100))%")
                        .font(.caption.monospacedDigit())
                }
                .font(.caption)
                if scanner.depthCoverage < 0.5 {
                    Text("Move closer, or add light. Dark and glossy surfaces measure badly.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            } else {
                Text(scanner.capability.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var captureButton: some View {
        Button {
            capture()
        } label: {
            Label(isSaving ? "Saving…" : "Capture", systemImage: "camera.aperture")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!scanner.isRunning || isSaving)
    }

    private func capture() {
        isSaving = true
        do {
            let capture = try scanner.capture()
            try controller.addScan(capture)
            isSaving = false
            dismiss()
        } catch {
            isSaving = false
            self.error = error.localizedDescription
        }
    }
}
