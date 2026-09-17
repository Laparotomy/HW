import CoreGraphics
import Foundation

/// Which clock the show follows.
enum ClockSource: String, Codable, CaseIterable, Identifiable {
    /// Free-running timer; no audio required.
    case freeRun
    /// Position of the loaded music file (the default for an ensemble show).
    case track
    /// Beat grid recovered from the microphone, for locking to a PA system or
    /// a DJ you have no digital link to.
    case listen

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .freeRun: return "Free run"
        case .track: return "Track"
        case .listen: return "Listen"
        }
    }
}

/// Where the show's tempo comes from.
enum TempoMode: String, Codable, CaseIterable, Identifiable {
    /// Follow the tempo recovered from the audio, falling back to the manual value
    /// while detection is still unsure of itself.
    case automatic
    /// Ignore detection and use the manual tempo, for music the analyser cannot
    /// read or a set that has to stay on a fixed grid.
    case manual

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .manual: return "Manual"
        }
    }
}

struct AudioSettings: Codable, Equatable {
    /// Below this, a detected tempo is treated as a guess and the manual value is
    /// used instead. See `BeatTracker.tempoConfidence`.
    static let confidenceThreshold: Double = 0.45

    var track: MediaReference?
    var clockSource: ClockSource = .freeRun
    var volume: Double = 1
    var loops: Bool = true
    var tempoMode: TempoMode = .automatic
    /// Tempo used by beat-driven modulation when detection is unavailable or the
    /// mode is manual.
    var manualBPM: Double = 120
    /// Positive values delay the visuals, to compensate for speaker distance
    /// or a projector's input lag.
    var latencyOffset: Double = 0

    init() {}

    /// Decoded field by field with defaults, so a show saved before `tempoMode`
    /// existed still opens instead of failing to decode.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        track = try container.decodeIfPresent(MediaReference.self, forKey: .track)
        clockSource = try container.decodeIfPresent(ClockSource.self, forKey: .clockSource) ?? .freeRun
        volume = try container.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        loops = try container.decodeIfPresent(Bool.self, forKey: .loops) ?? true
        tempoMode = try container.decodeIfPresent(TempoMode.self, forKey: .tempoMode) ?? .automatic
        manualBPM = try container.decodeIfPresent(Double.self, forKey: .manualBPM) ?? 120
        latencyOffset = try container.decodeIfPresent(Double.self, forKey: .latencyOffset) ?? 0
    }

    private enum CodingKeys: String, CodingKey {
        case track, clockSource, volume, loops, tempoMode, manualBPM, latencyOffset
    }
}

/// A saved show: canvas, layers and audio.
struct MappingProject: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String = "Untitled Show"
    /// Design resolution. Only the aspect ratio affects rendering; the number is
    /// there so a project can be authored against a known projector mode.
    var canvasSize: CGSize = CGSize(width: 1920, height: 1080)
    var layers: [MappingLayer] = []
    var audio: AudioSettings = AudioSettings()
    var background: RGBAColor = .black
    /// Surfaces captured with the camera, used as a reference underlay and, where
    /// the device measured depth, as the source of a curvature warp.
    var scans: [SurfaceScan] = []
    /// Scan shown under the stage while editing, if any.
    var activeScanID: UUID?
    /// How the projector throws its image. Needed to turn a scan into a warp.
    var optics: ProjectorOptics = ProjectorOptics()
    /// Where the audience stands relative to the projector.
    var audience: AudienceOffset = AudienceOffset()
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

    init() {}

    init(name: String) {
        self.name = name
    }

    /// Decoded field by field with defaults, so every show saved by an earlier
    /// version still opens. This struct has gained fields three times now; a
    /// synthesised decoder would have thrown away the user's work each time.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Show"
        canvasSize = try container.decodeIfPresent(CGSize.self, forKey: .canvasSize)
            ?? CGSize(width: 1920, height: 1080)
        layers = try container.decodeIfPresent([MappingLayer].self, forKey: .layers) ?? []
        audio = try container.decodeIfPresent(AudioSettings.self, forKey: .audio) ?? AudioSettings()
        background = try container.decodeIfPresent(RGBAColor.self, forKey: .background) ?? .black
        scans = try container.decodeIfPresent([SurfaceScan].self, forKey: .scans) ?? []
        activeScanID = try container.decodeIfPresent(UUID.self, forKey: .activeScanID)
        optics = try container.decodeIfPresent(ProjectorOptics.self, forKey: .optics)
            ?? ProjectorOptics()
        audience = try container.decodeIfPresent(AudienceOffset.self, forKey: .audience)
            ?? AudienceOffset()
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try container.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? Date()
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, canvasSize, layers, audio, background
        case scans, activeScanID, optics, audience, createdAt, modifiedAt
    }

    var canvasAspect: Double {
        canvasSize.height > 0 ? Double(canvasSize.width / canvasSize.height) : 16.0 / 9.0
    }

    func layer(with id: UUID) -> MappingLayer? { layers.first { $0.id == id } }

    /// Index in draw order (first element draws first, i.e. furthest back).
    func index(of id: UUID) -> Int? { layers.firstIndex { $0.id == id } }

    /// Media used anywhere in the project, for garbage-collecting the media folder.
    var referencedMedia: Set<String> {
        var names = Set<String>()
        for layer in layers {
            if let ref = layer.content.media { names.insert(ref.filename) }
            if let tex = layer.appearance.texture.image { names.insert(tex.filename) }
        }
        if let track = audio.track { names.insert(track.filename) }
        for scan in scans { names.insert(scan.imageFilename) }
        return names
    }

    var activeScan: SurfaceScan? {
        activeScanID.flatMap { id in scans.first { $0.id == id } }
    }

    static var demo: MappingProject {
        var project = MappingProject(name: "New Show")
        var layer = MappingLayer(name: "Colour Wash")
        layer.appearance.tint = RGBAColor(red: 0.35, green: 0.55, blue: 1)
        layer.appearance.tintAmount = 1
        layer.appearance.texture.pattern = .grid
        layer.appearance.texture.amount = 0.35
        layer.modulation = [ModulationRoute(source: .bass, target: .intensity, amount: 0.6)]
        project.layers = [layer]
        return project
    }
}
