import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

/// Music source, clock source, and live audio metering.
struct AudioPanel: View {
    @ObservedObject var controller: ShowController
    @ObservedObject private var audio: AudioEngineController
    @State private var isPickingTrack = false
    @State private var isPickingFromLibrary = false
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
                    Menu {
                        Button {
                            chooseFromLibrary()
                        } label: {
                            Label("Music library", systemImage: "music.note.list")
                        }
                        Button {
                            isPickingTrack = true
                        } label: {
                            Label("Files", systemImage: "folder")
                        }
                    } label: {
                        Text("Choose")
                    }
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
                Picker("Source", selection: Binding(
                    get: { controller.project.audio.tempoMode },
                    set: { controller.project.audio.tempoMode = $0 })) {
                    ForEach(TempoMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Detected")
                    Spacer()
                    Text(detectedText)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(controller.isFollowingDetectedTempo ? .primary : .secondary)
                }
                // The estimate is always *a* number; the bar says whether it is worth
                // following. Below the threshold automatic mode keeps using the manual
                // value rather than letting a bad guess drive the show.
                if audio.features.bpm > 0 {
                    meter("Confidence", audio.features.tempoConfidence,
                          controller.isFollowingDetectedTempo ? .green : .orange)
                }

                LabeledSlider(title: "Manual tempo", value: Binding(
                    get: { controller.project.audio.manualBPM },
                    set: { controller.project.audio.manualBPM = $0 }),
                    range: 60...200, format: { String(format: "%.0f BPM", $0) })

                HStack {
                    Button {
                        audio.tapTempo()
                    } label: {
                        Label("Tap tempo", systemImage: "hand.tap")
                    }
                    Spacer()
                    Button("Use detected") {
                        controller.adoptDetectedTempo()
                    }
                    .disabled(audio.features.bpm <= 0)
                }
                .buttonStyle(.bordered)

                Text(tempoExplanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("While the music plays") {
                Toggle("Animate only while music plays", isOn: Binding(
                    get: { controller.project.audio.animateOnlyWithMusic },
                    set: { controller.project.audio.animateOnlyWithMusic = $0 }))
                    .disabled(!controller.musicGateApplies)

                if !controller.musicGateApplies {
                    Text("Only applies on the Track and Listen clocks — free run has "
                         + "no music to wait for.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if controller.project.audio.clockSource == .listen
                            || controller.project.audio.track == nil {
                    // The gate is a level, and a level only means something against
                    // the room it is measured in. Showing it next to the live meter
                    // is the only honest way to set it.
                    LabeledSlider(title: "Starts above", value: Binding(
                        get: { controller.project.audio.musicGateLevel },
                        set: { controller.project.audio.musicGateLevel = $0 }),
                        range: 0.05...0.9, format: { String(format: "%.0f%%", $0 * 100) })
                    meter("Heard now", audio.features.level,
                          audio.features.level > controller.project.audio.musicGateLevel
                            ? .green : .secondary)
                    Text("Set it just above what the empty room reads. The show keeps "
                         + "running for \(String(format: "%.1f", AudioSettings.musicGateHold))s "
                         + "after the music drops, so a gap between tracks is not a "
                         + "stutter.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("The show holds still whenever the track is paused, and picks "
                         + "up from the same frame when it starts again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Streaming services") {
                Text("""
                     Apple Music, SoundCloud, Spotify and YouTube all send audio \
                     that no other app is allowed to read — the sound is decrypted \
                     inside their own player and never reaches here. Nothing can \
                     change that from inside an app, so there is no import for them.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("""
                     Listen mode is the way round it, and it is not a consolation \
                     prize: play the music from any app, or from the PA in the \
                     room, and the microphone gives the show its level, its bands \
                     and its beat. Music library above reaches the songs the device \
                     holds unencrypted, which is what a file needs to be for \
                     several phones to play it in step.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    controller.setClockSource(.listen)
                } label: {
                    Label("Switch the clock to Listen", systemImage: "ear")
                }
                .disabled(controller.project.audio.clockSource == .listen)
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
        .sheet(isPresented: $isPickingFromLibrary) {
            MusicLibraryPicker(onPick: { item in
                isPickingFromLibrary = false
                importFromLibrary(item)
            }, onCancel: {
                isPickingFromLibrary = false
            })
            .ignoresSafeArea()
        }
        .alert("Could not load track", isPresented: Binding(
            get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }

    private func chooseFromLibrary() {
        Task { @MainActor in
            guard await MediaImporter.requestMusicLibraryAccess() else {
                importError = MediaImporter.MusicImportError.notAuthorised.localizedDescription
                return
            }
            isPickingFromLibrary = true
        }
    }

    private func importFromLibrary(_ item: MPMediaItem) {
        Task { @MainActor in
            do {
                let ref = try await MediaImporter.importMusicLibraryItem(
                    item, projectID: controller.project.id)
                controller.setTrack(ref)
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private var detectedText: String {
        guard audio.features.bpm > 0 else { return "—" }
        return String(format: "%.0f BPM", audio.features.bpm)
    }

    private var tempoExplanation: String {
        switch controller.project.audio.tempoMode {
        case .automatic:
            return controller.isFollowingDetectedTempo
                ? "Following the music. Beat-driven layers are on the detected tempo."
                : "Listening. Until the estimate settles, the manual tempo is used."
        case .manual:
            return "Beat-driven layers run on the manual tempo, whatever the music does."
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
