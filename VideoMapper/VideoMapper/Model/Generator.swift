import Foundation

/// A procedurally generated abstract source.
///
/// The library is synthesised in the fragment shader rather than shipped as video
/// files. That is not a shortcut: for projection mapping it is strictly better.
/// A generator has no resolution (a 4K projector gets 4K, not an upscaled 1080p
/// file), no duration to loop or seek, no bytes in the project folder, and — because
/// it is a pure function of show time — every device in an ensemble draws an
/// identical frame with no drift correction at all.
enum GeneratorKind: String, Codable, CaseIterable, Identifiable {
    case plasma
    case clouds
    case tunnel
    case kaleidoscope
    case cells
    case rings
    case waves
    case grid
    case starfield
    case aurora
    case metaballs
    case strobe

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plasma: return "Plasma"
        case .clouds: return "Clouds"
        case .tunnel: return "Tunnel"
        case .kaleidoscope: return "Kaleidoscope"
        case .cells: return "Cells"
        case .rings: return "Rings"
        case .waves: return "Waves"
        case .grid: return "Grid"
        case .starfield: return "Starfield"
        case .aurora: return "Aurora"
        case .metaballs: return "Metaballs"
        case .strobe: return "Strobe"
        }
    }

    /// One line shown under the name in the browser, describing what it looks like
    /// and what it is good for.
    var detail: String {
        switch self {
        case .plasma: return "Flowing colour field. A dependable full-surface wash."
        case .clouds: return "Drifting fractal smoke. Soft, slow, good behind other layers."
        case .tunnel: return "Receding tunnel. Reads as depth on a flat wall."
        case .kaleidoscope: return "Mirrored symmetry. Strong on square and round surfaces."
        case .cells: return "Organic cracked cells that creep and shift."
        case .rings: return "Concentric pulses travelling outward. Pairs well with a beat."
        case .waves: return "Interfering wavefronts. Calm, continuous motion."
        case .grid: return "Perspective grid running to the horizon."
        case .starfield: return "Points streaming past the viewer."
        case .aurora: return "Vertical curtains of light, slowly swaying."
        case .metaballs: return "Merging blobs with soft edges."
        case .strobe: return "Hard full-field flashes. Drive it from the beat."
        }
    }

    /// SF Symbol used in the browser before the live thumbnail renders.
    var symbolName: String {
        switch self {
        case .plasma: return "drop.halffull"
        case .clouds: return "cloud.fill"
        case .tunnel: return "circle.circle"
        case .kaleidoscope: return "snowflake"
        case .cells: return "hexagon.fill"
        case .rings: return "smallcircle.filled.circle"
        case .waves: return "water.waves"
        case .grid: return "grid"
        case .starfield: return "sparkles"
        case .aurora: return "light.max"
        case .metaballs: return "circles.hexagongrid.fill"
        case .strobe: return "bolt.fill"
        }
    }

    /// Value handed to the shader. Zero means "not a generator", so these start at 1
    /// and must never be renumbered — projects store the kind by name, but a stale
    /// index in a running shader would silently draw the wrong thing.
    var shaderIndex: Float {
        switch self {
        case .plasma: return 1
        case .clouds: return 2
        case .tunnel: return 3
        case .kaleidoscope: return 4
        case .cells: return 5
        case .rings: return 6
        case .waves: return 7
        case .grid: return 8
        case .starfield: return 9
        case .aurora: return 10
        case .metaballs: return 11
        case .strobe: return 12
        }
    }

    /// Starting point that makes each generator look its best straight away, so
    /// adding one from the browser never lands on a black or blown-out frame.
    var defaultSettings: GeneratorSettings {
        var settings = GeneratorSettings()
        switch self {
        case .plasma:
            settings.palette = .neon
            settings.speed = 0.35
            settings.scale = 3
        case .clouds:
            settings.palette = .mist
            settings.speed = 0.15
            settings.scale = 2.5
            settings.complexity = 0.7
        case .tunnel:
            settings.palette = .ember
            settings.speed = 0.5
            settings.scale = 6
        case .kaleidoscope:
            settings.palette = .rainbow
            settings.speed = 0.25
            settings.scale = 4
            settings.complexity = 0.6
        case .cells:
            settings.palette = .toxic
            settings.speed = 0.2
            settings.scale = 5
        case .rings:
            settings.palette = .ice
            settings.speed = 0.6
            settings.scale = 7
        case .waves:
            settings.palette = .ice
            settings.speed = 0.4
            settings.scale = 5
        case .grid:
            settings.palette = .neon
            settings.speed = 0.5
            settings.scale = 8
        case .starfield:
            settings.palette = .mono
            settings.speed = 0.7
            settings.scale = 6
        case .aurora:
            settings.palette = .toxic
            settings.speed = 0.2
            settings.scale = 3
            settings.complexity = 0.5
        case .metaballs:
            settings.palette = .sunset
            settings.speed = 0.35
            settings.scale = 2.5
        case .strobe:
            settings.palette = .mono
            settings.speed = 2
            settings.audioSource = .beat
            settings.audioAmount = 1
        }
        return settings
    }
}

/// Colour ramp applied to a generator's scalar field.
///
/// Ramps are cosine gradients evaluated in the shader, so they stay smooth at any
/// projector resolution and cost four instructions.
enum GeneratorPalette: String, Codable, CaseIterable, Identifiable {
    case mono, ember, ice, neon, rainbow, sunset, toxic, mist

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mono: return "Mono"
        case .ember: return "Ember"
        case .ice: return "Ice"
        case .neon: return "Neon"
        case .rainbow: return "Rainbow"
        case .sunset: return "Sunset"
        case .toxic: return "Toxic"
        case .mist: return "Mist"
        }
    }

    var shaderIndex: Float {
        switch self {
        case .mono: return 0
        case .ember: return 1
        case .ice: return 2
        case .neon: return 3
        case .rainbow: return 4
        case .sunset: return 5
        case .toxic: return 6
        case .mist: return 7
        }
    }
}

/// Tunable parameters shared by every generator.
///
/// One parameter set for all kinds, rather than a bespoke struct each: it keeps the
/// inspector predictable, keeps the uniform block fixed-size, and means switching
/// kind on an existing layer preserves the feel you dialled in.
struct GeneratorSettings: Codable, Equatable {
    /// Motion rate. Zero freezes the generator on a still frame.
    var speed: Double = 0.4
    /// Feature size: low is a few large shapes, high is fine detail.
    var scale: Double = 4
    /// Extra octaves / turbulence, 0...1. Costs fill rate at the top end.
    var complexity: Double = 0.5
    var palette: GeneratorPalette = .neon
    /// Audio feature that drives the generator, on top of any modulation routes.
    var audioSource: ModulationSource = .none
    /// Depth of that drive, 0...1.
    var audioAmount: Double = 0.6
    /// Reseeds the noise so two layers of the same kind do not draw in lockstep.
    var variation: Double = 0

    static let speedRange: ClosedRange<Double> = 0...3
    static let scaleRange: ClosedRange<Double> = 0.5...16
    static let complexityRange: ClosedRange<Double> = 0...1
    static let variationRange: ClosedRange<Double> = 0...10

    /// Keeps hand-edited or synced values inside what the shader expects.
    func clamped() -> GeneratorSettings {
        var copy = self
        copy.speed = speed.clamped(to: Self.speedRange)
        copy.scale = scale.clamped(to: Self.scaleRange)
        copy.complexity = complexity.clamped(to: Self.complexityRange)
        copy.audioAmount = audioAmount.clamped(to: 0...1)
        copy.variation = variation.clamped(to: Self.variationRange)
        return copy
    }
}

extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
