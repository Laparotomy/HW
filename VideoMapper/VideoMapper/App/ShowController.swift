import AVFoundation
import Combine
import CoreGraphics
import Foundation
import Metal
import MultipeerConnectivity
import os

/// Central coordinator: owns the project, the audio engine, the peer link and the
/// show clock, and builds the frame the renderer draws.
///
/// Everything the UI touches lives here on the main actor. The renderer and the
/// audio tap are the only things that run elsewhere, and both talk to this class
/// through explicit hand-offs rather than shared mutable state.
@MainActor
final class ShowController: ObservableObject {

    // MARK: - Published state

    @Published var project: MappingProject {
        didSet { scheduleAutosave() }
    }
    @Published var selectedLayerID: UUID?
    @Published var isPlaying = false
    /// Deliberately *not* `@Published`: this advances every frame, and publishing it
    /// would invalidate the entire view tree at 60 Hz. The transport read-out polls
    /// it from a `TimelineView` instead.
    private(set) var showTime: Double = 0
    @Published var stageMode: StageMode = .move
    @Published private(set) var statusMessage: String?
    /// Set when a follower's media does not match the host's.
    @Published private(set) var trackMismatch = false
    /// Non-nil while a projector or TV is attached over HDMI or AirPlay.
    @Published var externalDisplay: ExternalDisplayInfo?

    enum StageMode: String, CaseIterable, Identifiable {
        case move, warp
        var id: String { rawValue }
        var displayName: String { self == .move ? "Move" : "Warp" }
    }

    let audio = AudioEngineController()
    let sync = SyncSession()
    /// Nil only on a device with no Metal support, in which case the stage shows
    /// an explanatory placeholder instead of crashing.
    let textureStore: TextureStore?
    let renderer: MetalRenderer?
    let device: MTLDevice?

    private let modulation = ModulationEngine()
    private let store = ProjectStore.shared
    private let log = Logger(subsystem: "app.videomapper", category: "Show")
    private var autosaveTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// Local free-run anchor: at `anchorLocalTime` the show was at `anchorShowTime`.
    private var anchorLocalTime: Double = HostClock.now
    private var anchorShowTime: Double = 0
    /// Most recent transport received from the host (followers only).
    private var hostTransport: TransportSnapshot?
    private var lastBroadcast: Double = 0
    private var lastFollowerAudioCheck: Double = 0

    // MARK: - Init

    /// The one controller the app runs on.
    ///
    /// A singleton because the projector's window lives in a *separate scene*, which
    /// UIKit creates and owns; it has to reach the same show the phone is editing,
    /// and a `@StateObject` in the SwiftUI hierarchy is not reachable from there.
    static let shared = ShowController(project: ProjectStore.shared.loadAll().first ?? .demo)

    init(project: MappingProject = .demo) {
        self.project = project
        let device = MTLCreateSystemDefaultDevice()
        self.device = device
        if let device {
            let textureStore = TextureStore(device: device)
            self.textureStore = textureStore
            self.renderer = MetalRenderer(device: device, textureStore: textureStore)
        } else {
            self.textureStore = nil
            self.renderer = nil
        }

        sync.delegate = self
        audio.configureSession(listening: false)
        try? self.store.prepareFolders(for: project.id)
        textureStore?.reconcile(project: project)
        loadTrackIfNeeded()

        // Rebuild GPU resources whenever the layer stack changes shape.
        $project
            .map { project in project.layers.map { LayerFingerprint(layer: $0) } }
            .removeDuplicates()
            .sink { [weak self] _ in
                // `project` is only ever mutated on the main actor, so the
                // publisher delivers here synchronously on main.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.textureStore?.reconcile(project: self.project)
                    self.modulation.prune(activeRouteIDs: self.activeRouteIDs)
                    self.modulation.pruneGenerators(
                        activeLayerIDs: Set(self.project.layers.map(\.id)))
                }
            }
            .store(in: &cancellables)
    }

    /// Identifies the parts of a layer that require GPU work when they change.
    private struct LayerFingerprint: Equatable {
        let id: UUID
        let content: String
        let overlay: UUID?

        init(layer: MappingLayer) {
            id = layer.id
            switch layer.content {
            case .solid: content = "solid"
            case .image(let ref): content = "image:\(ref.filename)"
            case .video(let ref, let playback):
                content = "video:\(ref.filename):\(playback.rate):\(playback.loops):\(playback.startOffset):\(playback.followsShowClock):\(playback.volume)"
            // Generator parameters reach the GPU as uniforms every frame, so only a
            // change of kind is worth a reconcile.
            case .generator(let kind, _): content = "generator:\(kind.rawValue)"
            }
            overlay = layer.appearance.texture.image?.id
        }
    }

    private var activeRouteIDs: Set<UUID> {
        Set(project.layers.flatMap { $0.modulation.map(\.id) })
    }

    // MARK: - Show clock

    private var cachedFrame: RenderFrame?
    private var cachedFrameTime: Double = -1

    /// Advances the clock and returns the frame to draw. Called once per display refresh.
    ///
    /// With a projector attached there are two views asking for a frame within a
    /// millisecond or two of each other. Both must draw the *same* frame: building it
    /// twice would advance the modulation envelopes at double rate, so the phone and
    /// the projector would visibly disagree.
    func makeFrame() -> RenderFrame {
        let now = HostClock.now
        if let cachedFrame, now - cachedFrameTime < 0.004 { return cachedFrame }

        updateShowTime()

        var frame = RenderFrame()
        frame.background = project.background
        frame.canvasAspect = project.canvasAspect
        frame.showTime = showTime
        frame.isPlaying = isPlaying
        frame.selectedLayerID = selectedLayerID

        let features = audio.features
        let fallbackBPM = project.audio.manualBPM
        frame.layers = project.layers.filter(\.isVisible).map { layer in
            let offsets = modulation.offsets(for: layer, features: features,
                                             showTime: showTime, fallbackBPM: fallbackBPM)
            return modulation.resolve(layer: layer, offsets: offsets)
        }

        if sync.role == .host { broadcastTransportIfNeeded() }
        if sync.role == .follower { reconcileFollowerAudio() }

        cachedFrame = frame
        cachedFrameTime = now
        return frame
    }

    private func updateShowTime() {
        // A follower always derives show time from the host's anchor plus its own
        // clock-offset estimate, so every device agrees to within the sync error.
        if sync.role == .follower, let transport = hostTransport {
            // Only assign on a real change: an identical value still fires
            // objectWillChange, which would re-render the UI every frame.
            if isPlaying != transport.isPlaying { isPlaying = transport.isPlaying }
            showTime = transport.showTime(atHostTime: sync.clock.hostNow) + project.audio.latencyOffset
            return
        }

        guard isPlaying else { return }
        switch project.audio.clockSource {
        case .track where audio.hasTrack:
            showTime = max(0, audio.trackPosition) + project.audio.latencyOffset
        case .track, .freeRun, .listen:
            showTime = anchorShowTime + (HostClock.now - anchorLocalTime) + project.audio.latencyOffset
        }
    }

    // MARK: - Transport

    func play() {
        guard sync.role != .follower else { return }
        anchorLocalTime = HostClock.now
        anchorShowTime = showTime
        isPlaying = true
        if audio.hasTrack, project.audio.clockSource != .listen {
            audio.play(from: max(0, showTime), loops: project.audio.loops, volume: project.audio.volume)
        }
        broadcastTransport()
    }

    func pause() {
        guard sync.role != .follower else { return }
        isPlaying = false
        anchorShowTime = showTime
        anchorLocalTime = HostClock.now
        audio.pause()
        broadcastTransport()
    }

    func togglePlayback() { isPlaying ? pause() : play() }

    func restart() {
        guard sync.role != .follower else { return }
        showTime = 0
        anchorShowTime = 0
        anchorLocalTime = HostClock.now
        if isPlaying, audio.hasTrack {
            audio.play(from: 0, loops: project.audio.loops, volume: project.audio.volume)
        }
        broadcastTransport()
    }

    func seek(to time: Double) {
        guard sync.role != .follower else { return }
        showTime = max(0, time)
        anchorShowTime = showTime
        anchorLocalTime = HostClock.now
        if audio.hasTrack, isPlaying {
            audio.play(from: showTime, loops: project.audio.loops, volume: project.audio.volume)
        }
        broadcastTransport()
    }

    // MARK: - Layers

    func addLayer(_ layer: MappingLayer) {
        project.layers.append(layer)
        selectedLayerID = layer.id
        broadcastProject()
    }

    /// Adds a generator layer from the library, filling the canvas.
    func addGeneratorLayer(_ kind: GeneratorKind) {
        addLayer(MappingLayer.make(generator: kind))
    }

    func addColorLayer() {
        var layer = MappingLayer(name: "Colour \(project.layers.count + 1)")
        layer.appearance.tint = RGBAColor(red: Double.random(in: 0.3...1),
                                          green: Double.random(in: 0.3...1),
                                          blue: Double.random(in: 0.3...1))
        layer.appearance.tintAmount = 1
        addLayer(layer)
    }

    func deleteLayer(id: UUID) {
        project.layers.removeAll { $0.id == id }
        if selectedLayerID == id { selectedLayerID = project.layers.last?.id }
        store.pruneMedia(for: project)
        broadcastProject()
    }

    func duplicateLayer(id: UUID) {
        guard let source = project.layer(with: id), let index = project.index(of: id) else { return }
        var copy = source
        copy.id = UUID()
        copy.name = "\(source.name) copy"
        // Fresh route ids so the duplicate gets its own modulation envelopes.
        copy.modulation = source.modulation.map { route in
            var route = route
            route.id = UUID()
            return route
        }
        // Nudge it so the copy is visible rather than exactly hidden behind the original.
        copy.transform.center = CGPoint(x: min(1, source.transform.center.x + 0.04),
                                        y: min(1, source.transform.center.y + 0.04))
        project.layers.insert(copy, at: index + 1)
        selectedLayerID = copy.id
        broadcastProject()
    }

    func moveLayers(from offsets: IndexSet, to destination: Int) {
        project.layers.move(fromOffsets: offsets, toOffset: destination)
        broadcastProject()
    }

    /// Applies an edit to a layer in place.
    func updateLayer(id: UUID, _ mutate: (inout MappingLayer) -> Void) {
        guard let index = project.index(of: id) else { return }
        mutate(&project.layers[index])
    }

    var selectedLayer: MappingLayer? {
        selectedLayerID.flatMap { project.layer(with: $0) }
    }

    /// Binding-friendly accessor used by the inspector.
    func binding(for id: UUID) -> MappingLayer? { project.layer(with: id) }

    // MARK: - Media

    func attachMedia(_ ref: MediaReference) {
        let layer = MappingLayer.make(from: ref, canvasAspect: project.canvasAspect)
        addLayer(layer)
    }

    func setTrack(_ ref: MediaReference) {
        project.audio.track = ref
        project.audio.clockSource = .track
        loadTrackIfNeeded()
        broadcastProject()
    }

    private func loadTrackIfNeeded() {
        guard let track = project.audio.track else {
            audio.unloadTrack()
            return
        }
        let url = store.mediaURL(for: track, projectID: project.id)
        audio.load(url: url, title: track.displayName)
    }

    /// Fingerprint used to warn when devices hold different copies of the music.
    private var trackFingerprint: String? {
        guard let track = project.audio.track else { return nil }
        return "\(track.displayName)|\(Int(track.duration * 100))"
    }

    // MARK: - Listen mode

    func setClockSource(_ source: ClockSource) {
        project.audio.clockSource = source
        Task {
            if source == .listen {
                await audio.startListening()
            } else {
                audio.stopListening()
            }
        }
        broadcastProject()
    }

    // MARK: - Persistence

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            // Coalesce the flood of changes a slider drag produces into one write.
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        do {
            try store.save(project)
        } catch {
            log.error("Save failed: \(error.localizedDescription, privacy: .public)")
            statusMessage = "Could not save: \(error.localizedDescription)"
        }
    }

    func openProject(_ newProject: MappingProject) {
        saveNow()
        audio.stop()
        isPlaying = false
        showTime = 0
        anchorShowTime = 0
        anchorLocalTime = HostClock.now
        modulation.reset()
        project = newProject
        selectedLayerID = newProject.layers.first?.id
        try? store.prepareFolders(for: newProject.id)
        textureStore?.reconcile(project: newProject)
        loadTrackIfNeeded()
        broadcastProject()
    }

    // MARK: - Sync

    func setRole(_ role: SyncRole) {
        sync.setRole(role)
        if role != .follower {
            hostTransport = nil
            trackMismatch = false
        }
        if role == .host { broadcastProject() }
    }

    private func broadcastTransportIfNeeded() {
        let now = HostClock.now
        // A heartbeat keeps late joiners and drifting followers aligned without
        // needing a message per frame.
        guard now - lastBroadcast > 2 else { return }
        broadcastTransport()
    }

    private func broadcastTransport() {
        guard sync.role == .host else { return }
        lastBroadcast = HostClock.now
        let snapshot = TransportSnapshot(isPlaying: isPlaying,
                                         anchorHostTime: HostClock.now,
                                         showTime: showTime,
                                         trackPosition: audio.hasTrack ? audio.trackPosition : 0,
                                         hasTrack: audio.hasTrack,
                                         trackFingerprint: trackFingerprint)
        sync.send(.transport(snapshot))
    }

    private func broadcastProject() {
        guard sync.role == .host else { return }
        guard let data = try? JSONEncoder().encode(project) else { return }
        sync.send(.project(data))
    }

    /// Sends a single parameter while a control is being dragged.
    func broadcastParameter(layerID: UUID, key: ParameterUpdate.Key, value: Double) {
        guard sync.role == .host else { return }
        sync.send(.parameter(ParameterUpdate(layerID: layerID, key: key, value: value)),
                  reliable: false)
    }

    private func apply(_ update: ParameterUpdate) {
        updateLayer(id: update.layerID) { layer in
            switch update.key {
            case .opacity: layer.appearance.opacity = update.value
            case .intensity: layer.appearance.intensity = update.value
            case .tintAmount: layer.appearance.tintAmount = update.value
            case .saturation: layer.appearance.saturation = update.value
            case .contrast: layer.appearance.contrast = update.value
            case .feather: layer.appearance.feather = update.value
            case .textureAmount: layer.appearance.texture.amount = update.value
            case .textureScale: layer.appearance.texture.scale = update.value
            case .visible: layer.isVisible = update.value > 0.5
            }
        }
    }

    /// Keeps a follower's music lined up with the host's.
    ///
    /// The follower does not stream audio — it plays its own copy of the file,
    /// scheduled to start at the host time the anchor implies. Drift is re-checked
    /// periodically and corrected by rescheduling.
    private func reconcileFollowerAudio() {
        guard let transport = hostTransport, transport.hasTrack, audio.hasTrack else { return }
        let now = HostClock.now
        guard now - lastFollowerAudioCheck > 2 else { return }
        lastFollowerAudioCheck = now

        guard transport.isPlaying else {
            if audio.isPlaying { audio.pause() }
            return
        }

        let expected = expectedTrackPosition(from: transport)
        let drift = audio.isPlaying ? abs(audio.trackPosition - expected) : .infinity
        // 40 ms is about where a listener starts to hear two speakers as separate.
        guard drift > 0.04 else { return }
        scheduleFollowerAudio(from: transport)
    }

    private func expectedTrackPosition(from transport: TransportSnapshot) -> Double {
        var position = transport.trackPosition + (sync.clock.hostNow - transport.anchorHostTime)
        if project.audio.loops, audio.duration > 0 {
            position = position.truncatingRemainder(dividingBy: audio.duration)
        }
        return max(0, position)
    }

    private func scheduleFollowerAudio(from transport: TransportSnapshot) {
        // Start a beat in the future so both devices have time to arm.
        let leadIn = 0.35
        let hostStart = sync.clock.hostNow + leadIn
        var position = transport.trackPosition + (hostStart - transport.anchorHostTime)
        if project.audio.loops, audio.duration > 0 {
            position = position.truncatingRemainder(dividingBy: audio.duration)
        }
        let localStart = sync.clock.localTime(forHostTime: hostStart)
        audio.play(from: max(0, position),
                   atHostTime: HostClock.hostTime(forSeconds: localStart),
                   loops: project.audio.loops,
                   volume: project.audio.volume)
    }
}

// MARK: - SyncSessionDelegate

extension ShowController: SyncSessionDelegate {
    nonisolated func syncSession(_ session: SyncSession, didReceive message: SyncMessage, from peer: MCPeerID) {
        Task { @MainActor in
            switch message {
            case .transport(let snapshot):
                guard self.sync.role == .follower else { return }
                self.hostTransport = snapshot
                self.trackMismatch = snapshot.hasTrack && snapshot.trackFingerprint != self.trackFingerprint
                if snapshot.isPlaying { self.scheduleFollowerAudioIfIdle(snapshot) }

            case .project(let data):
                guard self.sync.role == .follower,
                      let incoming = try? JSONDecoder().decode(MappingProject.self, from: data)
                else { return }
                self.applyFollowerProject(incoming)

            case .parameter(let update):
                guard self.sync.role == .follower else { return }
                self.apply(update)

            case .tempo(let bpm, _):
                self.project.audio.manualBPM = bpm > 0 ? bpm : self.project.audio.manualBPM

            case .hello(let name, let isHost):
                self.statusMessage = isHost ? "Following \(name)" : "\(name) joined"

            case .ping, .pong:
                break
            }
        }
    }

    nonisolated func syncSessionDidConnectPeer(_ session: SyncSession, peer: MCPeerID) {
        Task { @MainActor in
            guard self.sync.role == .host else { return }
            // Bring the newcomer fully up to date.
            if let data = try? JSONEncoder().encode(self.project) {
                self.sync.send(.project(data), to: peer)
            }
            self.broadcastTransport()
        }
    }

    private func scheduleFollowerAudioIfIdle(_ transport: TransportSnapshot) {
        guard audio.hasTrack, !audio.isPlaying else { return }
        scheduleFollowerAudio(from: transport)
    }

    /// Adopts the host's show, keeping this device's own media paths.
    ///
    /// The layer *layout* is authoritative from the host, but media lives in each
    /// device's own project folder; a follower that lacks a file simply draws that
    /// layer as a colour rather than failing the whole show.
    private func applyFollowerProject(_ incoming: MappingProject) {
        var adopted = incoming
        adopted.id = project.id

        // Media filenames are per-device (each import gets a fresh uuid), so a
        // host's reference will not resolve here. Fall back to matching on the
        // display name, which is what a user sees when they import "the same clip"
        // onto both phones.
        let localByName = Dictionary(
            project.layers.compactMap { $0.content.media }.map { ($0.displayName, $0) },
            uniquingKeysWith: { first, _ in first })

        func resolve(_ ref: MediaReference) -> MediaReference? {
            let url = store.mediaURL(for: ref, projectID: project.id)
            if FileManager.default.fileExists(atPath: url.path) { return ref }
            if let match = localByName[ref.displayName] { return match }
            return nil
        }

        var missing = 0
        adopted.layers = incoming.layers.map { layer in
            var layer = layer
            guard let ref = layer.content.media else { return layer }
            if let resolved = resolve(ref) {
                switch layer.content {
                case .video(_, let playback): layer.content = .video(resolved, playback)
                case .image: layer.content = .image(resolved)
                // Unreachable: neither carries media, so the guard above returned.
                case .solid, .generator: break
                }
            } else {
                // Draw the layer as a colour block rather than dropping it: the
                // mapping stays visible so the operator can see what is missing.
                missing += 1
                layer.content = .solid
                if layer.appearance.tintAmount == 0 { layer.appearance.tintAmount = 1 }
            }
            return layer
        }
        if let track = incoming.audio.track { adopted.audio.track = resolve(track) ?? project.audio.track }

        project = adopted
        textureStore?.reconcile(project: adopted)
        statusMessage = missing > 0 ? "\(missing) layer(s) missing media on this device" : nil
    }
}
