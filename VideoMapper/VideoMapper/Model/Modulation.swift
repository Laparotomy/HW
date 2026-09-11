import Foundation

/// Audio feature driving a parameter.
enum ModulationSource: String, Codable, CaseIterable, Identifiable {
    case none, level, bass, mid, treble, beat

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "Off"
        case .level: return "Level"
        case .bass: return "Bass"
        case .mid: return "Mid"
        case .treble: return "Treble"
        case .beat: return "Beat"
        }
    }
}

/// Parameter being driven.
enum ModulationTarget: String, Codable, CaseIterable, Identifiable {
    case intensity, opacity, scale, tintAmount, textureAmount, rotation

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .intensity: return "Intensity"
        case .opacity: return "Opacity"
        case .scale: return "Size"
        case .tintAmount: return "Colour"
        case .textureAmount: return "Texture"
        case .rotation: return "Rotation"
        }
    }
}

/// One audio-reactive route: `target += amount * source`.
struct ModulationRoute: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var source: ModulationSource = .bass
    var target: ModulationTarget = .intensity
    /// Signed depth, -1...1, so a route can duck as well as boost.
    var amount: Double = 0.5
    /// Envelope release, 0...1. Higher values decay more slowly.
    var smoothing: Double = 0.6
}
