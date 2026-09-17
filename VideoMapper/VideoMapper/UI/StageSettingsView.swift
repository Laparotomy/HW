import SwiftUI

/// Project-level settings: the shape of the canvas every layer lives inside.
///
/// The canvas is the projector's frame. Only its aspect ratio affects what is drawn
/// — the renderer works in normalized coordinates — but the pixel numbers are worth
/// keeping honest, because they are what you match against the projector's native
/// mode when deciding whether an image will be resampled.
struct StageSettingsView: View {
    @ObservedObject var controller: ShowController
    @Environment(\.dismiss) private var dismiss

    @State private var width: String = ""
    @State private var height: String = ""
    @State private var sizeError: String?
    @State private var isScanning = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Canvas") {
                    Picker("Shape", selection: Binding(
                        get: { CanvasPreset.matching(controller.project.canvasSize) },
                        set: { apply($0) })) {
                        ForEach(CanvasPreset.allCases) { Text($0.displayName).tag($0) }
                    }

                    LabeledContent("Current") {
                        Text(sizeDescription)
                            .font(.body.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack {
                        TextField("Width", text: $width)
                            .keyboardType(.numberPad)
                        Text("x").foregroundStyle(.secondary)
                        TextField("Height", text: $height)
                            .keyboardType(.numberPad)
                        Button("Set") { applyCustomSize() }
                            .buttonStyle(.bordered)
                    }

                    if let sizeError {
                        Text(sizeError)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text("""
                         Only the ratio changes what is drawn. Match the projector's \
                         native mode and the stage you edit on is the frame it will \
                         light up.
                         """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                scanSection
                projectorSection

                Section("Background") {
                    ColorPicker("Behind the layers", selection: Binding(
                        get: { controller.project.background.color },
                        set: { controller.project.background = RGBAColor($0) }),
                        supportsOpacity: false)
                    Text("""
                         Black is right for almost every show: a projector cannot \
                         project darkness, so anything lighter here lights up the \
                         whole surface.
                         """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Reset to black") {
                        controller.project.background = .black
                        controller.saveNow()
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Stage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        controller.saveNow()
                        dismiss()
                    }
                }
            }
            .onAppear(perform: loadFields)
            .sheet(isPresented: $isScanning) {
                ScanView(controller: controller)
            }
        }
    }

    // MARK: - Scans

    /// Captured surfaces: the reference photo you map against, and the depth that
    /// bends a layer around what was measured.
    @ViewBuilder
    private var scanSection: some View {
        Section("Surface scans") {
            Button {
                isScanning = true
            } label: {
                Label("Scan a surface", systemImage: "camera.viewfinder")
            }

            if controller.project.scans.isEmpty {
                Text("Hold the phone where the projector is and capture. The photo "
                     + "goes under the stage so you can line layers up against the "
                     + "real wall. On an iPhone with LiDAR the shape of the surface "
                     + "is measured too, and a layer can be bent to follow it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Reference", selection: Binding(
                    get: { controller.project.activeScanID },
                    set: { controller.project.activeScanID = $0 })) {
                    Text("None").tag(UUID?.none)
                    ForEach(controller.project.scans) { scan in
                        Text(scanLabel(scan)).tag(UUID?.some(scan.id))
                    }
                }

                LabeledSlider(title: "Show reference", value: $controller.referenceOpacity,
                              range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })

                if let scan = controller.project.activeScan {
                    Text(scan.hasDepth
                         ? "Measured. A layer can be bent to this surface from the Design tab."
                         : "Photo only — this capture carries no depth, so it lines up by eye.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(role: .destructive) {
                        controller.deleteScan(id: scan.id)
                    } label: {
                        Label("Delete this scan", systemImage: "trash")
                    }
                }
            }
        }
    }

    private func scanLabel(_ scan: SurfaceScan) -> String {
        scan.hasDepth ? "\(scan.name) · depth" : "\(scan.name) · photo"
    }

    // MARK: - Projector

    /// The two numbers that turn a scan into a warp, plus where the audience is.
    @ViewBuilder
    private var projectorSection: some View {
        Section("Projector and audience") {
            LabeledSlider(title: "Throw ratio", value: Binding(
                get: { controller.project.optics.throwRatio },
                set: { controller.project.optics.throwRatio = $0 }),
                range: ProjectorOptics.throwRatioRange,
                format: { String(format: "%.2f:1", $0) })
            LabeledSlider(title: "Lens offset", value: Binding(
                get: { controller.project.optics.verticalLensOffset },
                set: { controller.project.optics.verticalLensOffset = $0 }),
                range: ProjectorOptics.lensOffsetRange,
                format: { String(format: "%+.0f%%", $0 * 100) })
            Text("Both are printed in the projector's manual. Throw ratio is its "
                 + "distance divided by the image width; lens offset is how far "
                 + "above the lens the image sits.")
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledSlider(title: "Audience right", value: Binding(
                get: { controller.project.audience.right },
                set: { controller.project.audience.right = $0 }),
                range: AudienceOffset.range, format: { String(format: "%+.1f m", $0) })
            LabeledSlider(title: "Audience up", value: Binding(
                get: { controller.project.audience.up },
                set: { controller.project.audience.up = $0 }),
                range: AudienceOffset.range, format: { String(format: "%+.1f m", $0) })
            LabeledSlider(title: "Audience back", value: Binding(
                get: { controller.project.audience.back },
                set: { controller.project.audience.back = $0 }),
                range: AudienceOffset.range, format: { String(format: "%+.1f m", $0) })
            Text("Where people watch from, relative to the projector. A curved "
                 + "surface only looks wrong from somewhere other than the "
                 + "projector, so this is the viewpoint the correction is for.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sizeDescription: String {
        let size = controller.project.canvasSize
        return String(format: "%.0f x %.0f  (%.2f:1)", size.width, size.height,
                      controller.project.canvasAspect)
    }

    private func loadFields() {
        width = String(format: "%.0f", controller.project.canvasSize.width)
        height = String(format: "%.0f", controller.project.canvasSize.height)
    }

    private func apply(_ preset: CanvasPreset) {
        guard let size = preset.size else { return }
        controller.setCanvasSize(size)
        loadFields()
        sizeError = nil
    }

    private func applyCustomSize() {
        guard let w = Double(width.trimmingCharacters(in: .whitespaces)),
              let h = Double(height.trimmingCharacters(in: .whitespaces)),
              let size = CanvasPreset.validate(width: w, height: h) else {
            sizeError = "Enter two numbers between \(Int(CanvasPreset.minimumSide)) and "
                + "\(Int(CanvasPreset.maximumSide))."
            return
        }
        controller.setCanvasSize(size)
        loadFields()
        sizeError = nil
    }
}

/// Canvas shapes worth one tap. Portrait is in the list because a projector turned
/// on its side to light a doorway or a column is a normal thing to do.
enum CanvasPreset: String, CaseIterable, Identifiable {
    case hd, uhd, wuxga, sxga, square, portraitHD, custom

    var id: String { rawValue }

    var size: CGSize? {
        switch self {
        case .hd: return CGSize(width: 1920, height: 1080)
        case .uhd: return CGSize(width: 3840, height: 2160)
        case .wuxga: return CGSize(width: 1920, height: 1200)
        case .sxga: return CGSize(width: 1280, height: 1024)
        case .square: return CGSize(width: 1080, height: 1080)
        case .portraitHD: return CGSize(width: 1080, height: 1920)
        case .custom: return nil
        }
    }

    var displayName: String {
        switch self {
        case .hd: return "16:9 · 1920x1080"
        case .uhd: return "16:9 · 3840x2160"
        case .wuxga: return "16:10 · 1920x1200"
        case .sxga: return "5:4 · 1280x1024"
        case .square: return "1:1 · 1080x1080"
        case .portraitHD: return "9:16 · 1080x1920"
        case .custom: return "Custom"
        }
    }

    static let minimumSide: Double = 16
    static let maximumSide: Double = 16384

    static func matching(_ size: CGSize) -> CanvasPreset {
        allCases.first { $0.size == size } ?? .custom
    }

    /// Rejects sizes that would make the canvas undrawable — a zero side gives a
    /// degenerate aspect ratio, and absurd numbers are always a typo.
    static func validate(width: Double, height: Double) -> CGSize? {
        guard width.isFinite, height.isFinite,
              width >= minimumSide, height >= minimumSide,
              width <= maximumSide, height <= maximumSide else { return nil }
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}
