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

struct AudioSettings: Codable, Equatable {
    var track: MediaReference?
    var clockSource: ClockSource = .freeRun
    var volume: Double = 1
    var loops: Bool = true
    /// Manual tempo used by beat-driven modulation when no track is loaded.
    var manualBPM: Double = 120
    /// Positive values delay the visuals, to compensate for speaker distance
    /// or a projector's input lag.
    var latencyOffset: Double = 0
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
    var createdAt: Date = Date()
    var modifiedAt: Date = Date()

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
        return names
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
