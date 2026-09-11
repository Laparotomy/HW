import SwiftUI
import UniformTypeIdentifiers

/// Music source, clock source, and live audio metering.
struct AudioPanel: View {
    @ObservedObject var controller: ShowController
    @ObservedObject private var audio: AudioEngineController
    @State private var isPickingTrack = false
    @State private var importError: String?

    init(controller: ShowController) {
        self.controller = controller
        self._audio = ObservedObject(wrappedValue: controller.audio)
    }

    var body: some View {
        Form {
            Section("Music") {
                HStack {
                    VStack(alignment: .leading) {
                        Text(audio.trackTitle ?? "No track loaded")
                            .lineLimit(1)
                        if audio.duration > 0 {
                            Text(timecode(audio.duration))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Choose") { isPickingTrack = true }
                        .buttonStyle(.bordered)
                }

                Picker("Clock", selection: Binding(
                    get: { controller.project.audio.clockSource },
                    set: { controller.setClockSource($0) })) {
                    ForEach(ClockSource.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                Text(clockExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Loop track", isOn: Binding(
                    get: { controller.project.audio.loops },
                    set: { controller.project.audio.loops = $0 }))

                LabeledSlider(title: "Volume", value: Binding(
                    get: { controller.project.audio.volume },
                    set: {
                        controller.project.audio.volume = $0
                        controller.audio.setVolume($0)
                    }), range: 0...1, format: { String(format: "%.0f%%", $0 * 100) })

                LabeledSlider(title: "Visual delay", value: Binding(
                    get: { controller.project.audio.latencyOffset },
                    set: { controller.project.audio.latencyOffset = $0 }),
                    range: -0.5...0.5, format: { String(format: "%+.0f ms", $0 * 1000) })
            }

            Section("Tempo") {
                HStack {
                    Text("Detected")
                    Spacer()
                    Text(audio.features.bpm > 0 ? String(format: "%.0f BPM", audio.features.bpm) : "—")
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                LabeledSlider(title: "Manual tempo", value: Binding(
                    get: { controller.project.audio.manualBPM },
                    set: { controller.project.audio.manualBPM = $0 }),
                    range: 60...200, format: { String(format: "%.0f BPM", $0) })
                Button {
                    audio.tapTempo()
                } label: {
                    Label("Tap tempo", systemImage: "hand.tap")
                }
            }

            Section("Levels") {
                meter("Level", audio.features.level, .blue)
                meter("Bass", audio.features.bass, .purple)
                meter("Mid", audio.features.mid, .teal)
                meter("Treble", audio.features.treble, .orange)
                meter("Beat", audio.features.beat, .pink)
            }

            if let error = audio.lastError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $isPickingTrack, allowedContentTypes: [.audio]) { result in
            switch result {
            case .success(let url):
                Task { @MainActor in
                    do {
                        let ref = try await MediaImporter.importAudio(at: url, projectID: controller.project.id)
                        controller.setTrack(ref)
                    } catch {
                        importError = error.localizedDescription
                    }
                }
            case .failure(let error):
                importError = error.localizedDescription
            }
        }
        .alert("Could not load track", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private var clockExplanation: String {
        switch controller.project.audio.clockSource {
        case .freeRun:
            return "Visuals run on their own timer. Use this when there is no music."
        case .track:
            return "Visuals follow the loaded track's position. Joined devices play their own copy of the same file, started together."
        case .listen:
            return "The microphone drives the show, so it locks to music playing from a PA or another device."
        }
    }

    private func meter(_ title: String, _ value: Double, _ color: Color) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .frame(width: 56, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geometry.size.width * min(1, max(0, value))))
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(String(format: "%.0f percent", value * 100))
    }

    private func timecode(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
