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
                } else {
                    editView
                }
            }
            .navigationTitle(controller.project.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(isPerforming ? .hidden : .visible, for: .navigationBar)
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
        .statusBarHidden(isPerforming)
    }

    // MARK: - Editing

    private var editView: some View {
        VStack(spacing: 0) {
            StageView(controller: controller)
                .frame(maxWidth: .infinity)
                .frame(height: 260)

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

            Picker("Stage mode", selection: $controller.stageMode) {
                ForEach(ShowController.StageMode.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 130)
        }
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
            Text(timecode(controller.showTime))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Show time")
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
