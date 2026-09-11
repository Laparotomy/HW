import PhotosUI
import SwiftUI

/// Everything about the selected layer: shape, look, texture, and audio routing.
struct InspectorPanel: View {
    @ObservedObject var controller: ShowController
    @State private var texturePickerItem: PhotosPickerItem?

    var body: some View {
        Group {
            if let layer = controller.selectedLayer {
                Form {
                    transformSection(layer)
                    lookSection(layer)
                    textureSection(layer)
                    if case .video(let ref, let playback) = layer.content {
                        videoSection(layer: layer, ref: ref, playback: playback)
                    }
                    if case .generator(let kind, let settings) = layer.content {
                        generatorSection(layer: layer, kind: kind, settings: settings)
                    }
                    modulationSection(layer)
                }
                .formStyle(.grouped)
            } else {
                ContentUnavailableView("No layer selected",
                                       systemImage: "square.3.layers.3d",
                                       description: Text("Pick a layer in the Layers tab, or tap one on the stage."))
            }
        }
    }

    /// Read/write access to the selected layer.
    private func binding(_ id: UUID) -> Binding<MappingLayer> {
        Binding(
            get: { controller.project.layer(with: id) ?? MappingLayer(name: "") },
            set: { updated in
                guard let index = controller.project.index(of: id) else { return }
                controller.project.layers[index] = updated
            })
    }

    // MARK: - Transform

    @ViewBuilder
    private func transformSection(_ layer: MappingLayer) -> some View {
        let layerBinding = binding(layer.id)
        Section("Shape") {
            TextField("Name", text: layerBinding.name)

            LabeledSlider(title: "Width", value: layerBinding.transform.size.width.double,
                          range: 0.02...2, format: percent)
            LabeledSlider(title: "Height", value: layerBinding.transform.size.height.double,
                          range: 0.02...2, format: percent)
            LabeledSlider(title: "Rotation", value: layerBinding.transform.rotation,
                          range: -Double.pi...Double.pi,
                          format: { "\(Int($0 * 180 / .pi))°" })
            LabeledSlider(title: "Position X", value: layerBinding.transform.center.x.double,
                          range: -0.5...1.5, format: percent)
            LabeledSlider(title: "Position Y", value: layerBinding.transform.center.y.double,
                          range: -0.5...1.5, format: percent)

            HStack {
                Button("Fit canvas") {
                    controller.updateLayer(id: layer.id) {
                        $0.transform.center = CGPoint(x: 0.5, y: 0.5)
                        $0.transform.size = CGSize(width: 1, height: 1)
                        $0.transform.rotation = 0
                    }
                }
                Spacer()
                Button("Reset warp") {
                    controller.updateLayer(id: layer.id) { $0.transform.resetWarp() }
                }
                .disabled(!layer.transform.isWarped)
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Look

    @ViewBuilder
    private func lookSection(_ layer: MappingLayer) -> some View {
        let layerBinding = binding(layer.id)
        Section("Look") {
            LabeledSlider(title: "Intensity", value: layerBinding.appearance.intensity, range: 0...4,
                          format: { String(format: "%.2fx", $0) }) { value in
                controller.broadcastParameter(layerID: layer.id, key: .intensity, value: value)
            }
            LabeledSlider(title: "Opacity", value: layerBinding.appearance.opacity, range: 0...1,
                          format: percent) { value in
                controller.broadcastParameter(layerID: layer.id, key: .opacity, value: value)
            }

            ColorPicker("Colour", selection: Binding(
                get: { layer.appearance.tint.color },
                set: { newValue in
                    controller.updateLayer(id: layer.id) { $0.appearance.tint = RGBAColor(newValue) }
                }), supportsOpacity: false)

            LabeledSlider(title: "Colour mix", value: layerBinding.appearance.tintAmount, range: 0...1,
                          format: percent) { value in
                controller.broadcastParameter(layerID: layer.id, key: .tintAmount, value: value)
            }
            LabeledSlider(title: "Saturation", value: layerBinding.appearance.saturation, range: 0...2,
                          format: percent)
            LabeledSlider(title: "Contrast", value: layerBinding.appearance.contrast, range: 0...2,
                          format: percent)
            LabeledSlider(title: "Edge feather", value: layerBinding.appearance.feather, range: 0...0.5,
                          format: percent)

            Picker("Blend", selection: layerBinding.appearance.blendMode) {
                ForEach(BlendMode.allCases) { Text($0.displayName).tag($0) }
            }
        }
    }

    // MARK: - Texture

    @ViewBuilder
    private func textureSection(_ layer: MappingLayer) -> some View {
        let layerBinding = binding(layer.id)
        Section("Texture") {
            Picker("Pattern", selection: layerBinding.appearance.texture.pattern) {
                ForEach(TexturePattern.allCases) { Text($0.displayName).tag($0) }
            }
            if layer.appearance.texture.pattern != .none {
                LabeledSlider(title: "Amount", value: layerBinding.appearance.texture.amount,
                              range: 0...1, format: percent) { value in
                    controller.broadcastParameter(layerID: layer.id, key: .textureAmount, value: value)
                }
                LabeledSlider(title: "Tiling", value: layerBinding.appearance.texture.scale,
                              range: 1...64, format: { String(format: "%.0f", $0) })
                LabeledSlider(title: "Scroll X", value: layerBinding.appearance.texture.scrollX,
                              range: -2...2, format: { String(format: "%.2f", $0) })
                LabeledSlider(title: "Scroll Y", value: layerBinding.appearance.texture.scrollY,
                              range: -2...2, format: { String(format: "%.2f", $0) })
            }
            if layer.appearance.texture.pattern == .custom {
                PhotosPicker(selection: $texturePickerItem, matching: .images) {
                    Label(layer.appearance.texture.image?.displayName ?? "Choose image",
                          systemImage: "photo")
                }
                .onChange(of: texturePickerItem) { _, item in
                    guard let item else { return }
                    texturePickerItem = nil
                    Task { @MainActor in
                        if let ref = try? await MediaImporter.importItem(item, projectID: controller.project.id) {
                            controller.updateLayer(id: layer.id) { $0.appearance.texture.image = ref }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Video

    @ViewBuilder
    private func videoSection(layer: MappingLayer, ref: MediaReference,
                              playback: VideoPlayback) -> some View {
        let playbackBinding = Binding<VideoPlayback>(
            get: { playback },
            set: { newValue in
                controller.updateLayer(id: layer.id) { $0.content = .video(ref, newValue) }
            })

        Section("Clip") {
            Toggle("Loop", isOn: playbackBinding.loops)
            Toggle("Lock to show clock", isOn: playbackBinding.followsShowClock)
            LabeledSlider(title: "Speed", value: playbackBinding.rate, range: 0.1...3,
                          format: { String(format: "%.2fx", $0) })
            LabeledSlider(title: "Clip volume", value: playbackBinding.volume, range: 0...1,
                          format: percent)
            if ref.duration > 0 {
                LabeledSlider(title: "Start at", value: playbackBinding.startOffset,
                              range: 0...max(0.1, ref.duration),
                              format: { String(format: "%.1fs", $0) })
            }
            Text(String(format: "%.0f x %.0f · %.1fs", ref.pixelSize.width, ref.pixelSize.height, ref.duration))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Generator

    @ViewBuilder
    private func generatorSection(layer: MappingLayer, kind: GeneratorKind,
                                  settings: GeneratorSettings) -> some View {
        let kindBinding = Binding<GeneratorKind>(
            get: { kind },
            set: { newKind in
                // Keep the dialled-in parameters when swapping kind: the settings are
                // shared across the library on purpose, so switching is an A/B test
                // rather than starting over.
                controller.updateLayer(id: layer.id) { $0.content = .generator(newKind, settings) }
            })
        let settingsBinding = Binding<GeneratorSettings>(
            get: { settings },
            set: { newValue in
                controller.updateLayer(id: layer.id) { $0.content = .generator(kind, newValue) }
            })

        Section("Source") {
            Picker("Pattern", selection: kindBinding) {
                ForEach(GeneratorKind.allCases) { Text($0.displayName).tag($0) }
            }
            Text(kind.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Palette", selection: settingsBinding.palette) {
                ForEach(GeneratorPalette.allCases) { Text($0.displayName).tag($0) }
            }
            // Grouped to stay clear of ViewBuilder's ten-child limit in this section.
            Group {
                LabeledSlider(title: "Speed", value: settingsBinding.speed,
                              range: GeneratorSettings.speedRange,
                              format: { String(format: "%.2fx", $0) })
                LabeledSlider(title: "Detail size", value: settingsBinding.scale,
                              range: GeneratorSettings.scaleRange,
                              format: { String(format: "%.1f", $0) })
                LabeledSlider(title: "Complexity", value: settingsBinding.complexity,
                              range: GeneratorSettings.complexityRange, format: percent)
                LabeledSlider(title: "Variation", value: settingsBinding.variation,
                              range: GeneratorSettings.variationRange,
                              format: { String(format: "%.1f", $0) })
            }

            Picker("Driven by", selection: settingsBinding.audioSource) {
                ForEach(ModulationSource.allCases) { Text($0.displayName).tag($0) }
            }
            if settings.audioSource != .none {
                LabeledSlider(title: "Drive depth", value: settingsBinding.audioAmount,
                              range: 0...1, format: percent)
            }

            Button("Reset to default") {
                controller.updateLayer(id: layer.id) {
                    $0.content = .generator(kind, kind.defaultSettings)
                }
            }
        }
    }

    // MARK: - Modulation

    @ViewBuilder
    private func modulationSection(_ layer: MappingLayer) -> some View {
        Section("Audio reactive") {
            ForEach(Array(layer.modulation.enumerated()), id: \.element.id) { index, route in
                let routeBinding = Binding<ModulationRoute>(
                    get: {
                        guard let current = controller.project.layer(with: layer.id),
                              current.modulation.indices.contains(index) else { return route }
                        return current.modulation[index]
                    },
                    set: { newValue in
                        controller.updateLayer(id: layer.id) { layer in
                            guard layer.modulation.indices.contains(index) else { return }
                            layer.modulation[index] = newValue
                        }
                    })
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Picker("", selection: routeBinding.source) {
                            ForEach(ModulationSource.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker("", selection: routeBinding.target) {
                            ForEach(ModulationTarget.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                    }
                    LabeledSlider(title: "Depth", value: routeBinding.amount, range: -1...1,
                                  format: percent)
                    LabeledSlider(title: "Smoothing", value: routeBinding.smoothing, range: 0...0.99,
                                  format: percent)
                }
                .padding(.vertical, 4)
            }
            .onDelete { offsets in
                controller.updateLayer(id: layer.id) { $0.modulation.remove(atOffsets: offsets) }
            }

            Button {
                controller.updateLayer(id: layer.id) { $0.modulation.append(ModulationRoute()) }
            } label: {
                Label("Add route", systemImage: "plus")
            }
        }
    }

    private var percent: (Double) -> String {
        { String(format: "%.0f%%", $0 * 100) }
    }
}

/// Slider with a title and a live readout, plus an optional hook for broadcasting
/// the value to connected devices while it moves.
struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    var onChange: ((Double) -> Void)?

    init(title: String, value: Binding<Double>, range: ClosedRange<Double>,
         format: @escaping (Double) -> String = { String(format: "%.2f", $0) },
         onChange: ((Double) -> Void)? = nil) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text(format(value))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: Binding(get: { value }, set: { newValue in
                value = newValue
                onChange?(newValue)
            }), in: range)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(format(value))
    }
}

/// Bridges `CGFloat` model properties to the `Double` bindings SwiftUI controls want.
extension Binding where Value == CGFloat {
    var double: Binding<Double> {
        Binding<Double>(get: { Double(wrappedValue) }, set: { wrappedValue = CGFloat($0) })
    }
}
