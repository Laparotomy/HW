import SwiftUI

/// Root screen: stage on top, transport in the middle, editing panels below.
///
/// Perform mode hides everything but the stage — during a show the phone is
/// usually propped behind a projector and any stray tap on a slider is a mistake.
struct ContentView: View {
    @ObservedObject var controller: ShowController
    @State private var panel: Panel = .layers
    @State private var isPerforming = false
    @State private var showsBrowser = false
    @State private var stageSettings = false
    /// The stage taken full-screen while still editable, so a mapping can be dialled
    /// in at the size it will actually be seen rather than in a 260-point strip.
    @State private var isStageExpanded = false

    enum Panel: String, CaseIterable, Identifiable {
        case layers, look, audio, sync
        var id: String { rawValue }
        var title: String {
            switch self {
            case .layers: return "Layers"
            case .look: return "Design"
            case .audio: return "Audio"
            case .sync: return "Sync"
            }
        }
        var icon: String {
            switch self {
            case .layers: return "square.3.layers.3d"
            case .look: return "slider.horizontal.3"
            case .audio: return "waveform"
            case .sync: return "antenna.radiowaves.left.and.right"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isPerforming {
                    performView
                } else if isStageExpanded {
                    expandedStage
                } else {
                    editView
                }
            }
            .navigationTitle(controller.project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isChromeHidden ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showsBrowser = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    .accessibilityLabel("Shows")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // The frame's shape changes often enough — a different projector,
                    // a screen turned on its side — that burying it one sheet deep
                    // was a tap too many.
                    Menu {
                        Picker("Frame", selection: Binding(
                            get: { CanvasPreset.matching(controller.project.canvasSize) },
                            set: { preset in
                                // "Custom" has no size of its own; it is where the
                                // numbers are typed, so it opens the sheet.
                                if let size = preset.size {
                                    controller.setCanvasSize(size)
                                } else {
                                    stageSettings = true
                                }
                            })) {
                            ForEach(CanvasPreset.allCases) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        Divider()
                        Button("Stage settings…") { stageSettings = true }
                    } label: {
                        Image(systemName: "aspectratio")
                    }
                    .accessibilityLabel("Frame format")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        withAnimation { isPerforming = true }
                    } label: {
                        Image(systemName: "play.rectangle")
                    }
                    .accessibilityLabel("Perform")
                }
            }
        }
        .sheet(isPresented: $showsBrowser) {
            ShowsBrowser(controller: controller)
        }
        .sheet(isPresented: $stageSettings) {
            StageSettingsView(controller: controller)
        }
        .statusBarHidden(isChromeHidden)
    }

    /// True whenever the stage has the screen to itself.
    private var isChromeHidden: Bool { isPerforming || isStageExpanded }

    // MARK: - Editing

    private var editView: some View {
        VStack(spacing: 0) {
            StageView(controller: controller)
                .frame(maxWidth: .infinity)
                .frame(height: 260)
                .overlay(alignment: .topTrailing) {
                    Button {
                        withAnimation { isStageExpanded = true }
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.footnote.weight(.semibold))
                            .padding(7)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(8)
                    .accessibilityLabel("Expand stage")
                }

            transportBar
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.bar)

            Picker("Panel", selection: $panel) {
                ForEach(Panel.allCases) { panel in
                    Label(panel.title, systemImage: panel.icon).tag(panel)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .padding(.horizontal)
            .padding(.top, 6)

            Divider().padding(.top, 6)

            switch panel {
            case .layers: LayersPanel(controller: controller)
            case .look: InspectorPanel(controller: controller)
            case .audio: AudioPanel(controller: controller)
            case .sync: SyncPanel(controller: controller)
            }
        }
    }

    private var transportBar: some View {
        HStack(spacing: 14) {
            Button {
                controller.togglePlayback()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.borderedProminent)
            .disabled(controller.sync.role == .follower)
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            Button {
                controller.restart()
            } label: {
                Image(systemName: "backward.end.fill")
            }
            .buttonStyle(.bordered)
            .disabled(controller.sync.role == .follower)
            .accessibilityLabel("Restart")

            TimecodeView(controller: controller)

            if controller.externalDisplay != nil {
                Image(systemName: "tv")
                    .foregroundStyle(.green)
                    .accessibilityLabel("Projector connected")
            }

            Spacer()

            displayMenu
                .buttonStyle(.bordered)

            Picker("Stage mode", selection: $controller.stageMode) {
                ForEach(ShowController.StageMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 120)
        }
    }

    /// Switches the stage between the picture, the mapping and both, and says whether
    /// the layers you are not editing show their grids too.
    private var displayMenu: some View {
        Menu {
            Picker("Show", selection: $controller.stageDisplay) {
                ForEach(ShowController.StageDisplay.allCases) { mode in
                    Label(mode.displayName, systemImage: mode.symbolName).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Divider()

            Toggle("Grids on every layer", isOn: $controller.showsAllLayerGrids)
        } label: {
            Image(systemName: controller.stageDisplay.symbolName)
        }
        .accessibilityLabel("Stage shows \(controller.stageDisplay.displayName)")
    }

    // MARK: - Expanded stage

    /// Editing, with the stage taking the whole screen.
    ///
    /// Every gesture the small stage answers to still works here — this is the same
    /// view, given more room — so corners can be dragged and points added at a size
    /// where a few pixels of misalignment are actually visible.
    private var expandedStage: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            StageView(controller: controller)
                .ignoresSafeArea()

            HStack(spacing: 12) {
                Button {
                    withAnimation { isStageExpanded = false }
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                }
                .accessibilityLabel("Collapse stage")

                Picker("Stage mode", selection: $controller.stageMode) {
                    ForEach(ShowController.StageMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)

                Picker("Show", selection: $controller.stageDisplay) {
                    ForEach(ShowController.StageDisplay.allCases) { mode in
                        Image(systemName: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)

                Spacer()

                if controller.sync.role != .follower {
                    Button {
                        controller.togglePlayback()
                    } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                }
            }
            .font(.title3)
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal)
            .padding(.top, 8)
        }
        .persistentSystemOverlays(.hidden)
    }

    // MARK: - Performing

    private var performView: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            StageView(controller: controller)
                .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    withAnimation { isPerforming = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Exit perform mode")

                // Mid-show a mapping sometimes needs a nudge. Warp mode reaches the
                // handles without leaving the full-screen output.
                Picker("Stage mode", selection: $controller.stageMode) {
                    ForEach(ShowController.StageMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 130)

                displayMenu
                    .font(.title2)

                if controller.sync.role != .follower {
                    Button {
                        controller.togglePlayback()
                    } label: {
                        Image(systemName: controller.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                    }
                    .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                }
            }
            .foregroundStyle(.white.opacity(0.75))
            .padding()
        }
        .persistentSystemOverlays(.hidden)
    }

}

/// Show-clock read-out.
///
/// Polls the clock on its own schedule so the rest of the interface is not
/// re-rendered every frame just to move a digit.
struct TimecodeView: View {
    let controller: ShowController

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            HStack(spacing: 5) {
                Text(timecode(controller.showTime))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Show time")
                // A frozen clock with no explanation looks like a crash. This says
                // the show is deliberately holding until it hears something.
                if controller.isWaitingForMusic {
                    Image(systemName: "ear")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityLabel("Waiting for music")
                }
            }
        }
    }

    private func timecode(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let secs = Int(clamped) % 60
        let hundredths = Int((clamped - floor(clamped)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, secs, hundredths)
    }
}
