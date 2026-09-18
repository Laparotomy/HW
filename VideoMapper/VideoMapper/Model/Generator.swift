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
    case spiral
    case moire
    case lightning
    case fireflies
    case hexes
    case liquid
    case sweep
    case bars
    case confetti
    case ripple
    case matrix
    case nebula

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
        case .spiral: return "Spiral"
        case .moire: return "Moiré"
        case .lightning: return "Lightning"
        case .fireflies: return "Fireflies"
        case .hexes: return "Hexes"
        case .liquid: return "Liquid"
        case .sweep: return "Sweep"
        case .bars: return "Bars"
        case .confetti: return "Confetti"
        case .ripple: return "Ripple"
        case .matrix: return "Rain"
        case .nebula: return "Nebula"
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
        case .aurora: return "Bands of light, slowly swaying."
        case .metaballs: return "Merging blobs with soft edges."
        case .strobe: return "Hard full-field flashes. Drive it from the beat."
        case .spiral: return "Turning spiral arms. Holds the eye on a round surface."
        case .moire: return "Two line sets beating against each other. Very strong on flat panels."
        case .lightning: return "Branching arcs that strike and fade. Best on the beat."
        case .fireflies: return "Sparse drifting glows on black. Quiet, and cheap to run."
        case .hexes: return "Hexagonal tiles lighting in their own time."
        case .liquid: return "A refracting fluid surface with caustic highlights."
        case .sweep: return "A bar of light crossing the surface. Set its angle with Detail."
        case .bars: return "A level meter. Feed it the music and it becomes one."
        case .confetti: return "Flakes falling past. Reads well on a tall surface."
        case .ripple: return "Drops landing and spreading. Sparse by design."
        case .matrix: return "Trails falling down columns, brightest at the head."
        case .nebula: return "Layered gas lit from inside. The richest of the washes."
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
        case .spiral: return "hurricane"
        case .moire: return "line.3.horizontal"
        case .lightning: return "bolt.horizontal.fill"
        case .fireflies: return "sparkle"
        case .hexes: return "hexagon.righthalf.filled"
        case .liquid: return "drop.fill"
        case .sweep: return "rectangle.portrait.and.arrow.right"
        case .bars: return "chart.bar.fill"
        case .confetti: return "snowflake.circle"
        case .ripple: return "circle.hexagongrid"
        case .matrix: return "cloud.rain.fill"
        case .nebula: return "moon.stars.fill"
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
        case .spiral: return 13
        case .moire: return 14
        case .lightning: return 15
        case .fireflies: return 16
        case .hexes: return 17
        case .liquid: return 18
        case .sweep: return 19
        case .bars: return 20
        case .confetti: return 21
        case .ripple: return 22
        case .matrix: return 23
        case .nebula: return 24
        }
    }

    /// Highest index the shader's dispatch switch covers. A kind numbered past this
    /// would fall through to black, which is why the tests pin it.
    static let highestShaderIndex: Float = 24

    /// Which shelf of the browser a source sits on.
    ///
    /// The library is past the size where one flat grid is scannable — you now scroll
    /// to find the thing you already know you want. Grouping by what a source *does*
    /// on a wall, rather than by how it is computed, is what makes that scroll short.
    var family: GeneratorFamily {
        switch self {
        case .plasma, .clouds, .waves, .aurora, .metaballs, .liquid, .ripple, .nebula:
            return .washes
        case .grid, .kaleidoscope, .cells, .moire, .hexes:
            return .structure
        case .tunnel, .spiral:
            return .depth
        case .starfield, .fireflies, .confetti, .matrix:
            return .particles
        case .rings, .strobe, .lightning, .sweep, .bars:
            return .hits
        }
    }

    /// How hard the browser's preview drives the source.
    ///
    /// The beat-driven ones sit dark between hits, so a preview rendered at rest is
    /// an honest picture of one frame and a useless picture of the source. These are
    /// shown lit.
    var previewDrive: Float {
        switch family {
        case .hits: return 0.85
        default: return 0.35
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
        case .spiral:
            settings.palette = .dusk
            settings.speed = 0.3
            settings.scale = 5
            settings.complexity = 0.4
        case .moire:
            settings.palette = .mono
            settings.speed = 0.5
            settings.scale = 6
        case .lightning:
            settings.palette = .ice
            settings.speed = 1
            settings.scale = 4
            settings.complexity = 0.6
            settings.audioSource = .beat
            settings.audioAmount = 0.8
        case .fireflies:
            settings.palette = .ember
            settings.speed = 0.3
            settings.scale = 4
        case .hexes:
            settings.palette = .ocean
            settings.speed = 0.5
            settings.scale = 6
        case .liquid:
            settings.palette = .ocean
            settings.speed = 0.3
            settings.scale = 4
            settings.complexity = 0.6
        case .sweep:
            settings.palette = .mono
            settings.speed = 0.6
            settings.scale = 5
            // Detail is the bar's angle here, and a vertical bar crossing a wide
            // wall is the shape this is reached for.
            settings.complexity = 0.5
            settings.audioSource = .beat
            settings.audioAmount = 0.5
        case .bars:
            settings.palette = .magma
            settings.speed = 0.8
            settings.scale = 8
            settings.audioSource = .bass
            settings.audioAmount = 1
        case .confetti:
            settings.palette = .candy
            settings.speed = 0.5
            settings.scale = 5
        case .ripple:
            settings.palette = .ice
            settings.speed = 0.6
            settings.scale = 6
        case .matrix:
            settings.palette = .toxic
            settings.speed = 0.6
            settings.scale = 6
        case .nebula:
            settings.palette = .dusk
            settings.speed = 0.15
            settings.scale = 2.5
            settings.complexity = 0.7
        }
        return settings
    }
}

/// A shelf of the source library.
enum GeneratorFamily: String, CaseIterable, Identifiable {
    case washes
    case structure
    case depth
    case particles
    case hits

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .washes: return "Washes"
        case .structure: return "Structure"
        case .depth: return "Depth"
        case .particles: return "Particles"
        case .hits: return "Hits"
        }
    }

    var detail: String {
        switch self {
        case .washes:
            return "Continuous colour over the whole surface. What you reach for first."
        case .structure:
            return "Lines, tiles and symmetry. They show a surface's shape rather than hide it."
        case .depth:
            return "Perspective on a flat wall — the illusion does the work."
        case .particles:
            return "Discrete points on black. Sparse, so overlapping layers stay readable."
        case .hits:
            return "Built to be driven by the music. Quiet between beats, by design."
        }
    }

    var symbolName: String {
        switch self {
        case .washes: return "paintbrush.fill"
        case .structure: return "square.grid.3x3"
        case .depth: return "cube"
        case .particles: return "sparkles"
        case .hits: return "waveform.path.ecg"
        }
    }

    var kinds: [GeneratorKind] {
        GeneratorKind.allCases.filter { $0.family == self }
    }
}

/// Colour ramp applied to a generator's scalar field.
///
/// Ramps are cosine gradients evaluated in the shader, so they stay smooth at any
/// projector resolution and cost four instructions.
enum GeneratorPalette: String, Codable, CaseIterable, Identifiable {
    case mono, ember, ice, neon, rainbow, sunset, toxic, mist
    case magma, ocean, candy, dusk

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
        case .magma: return "Magma"
        case .ocean: return "Ocean"
        case .candy: return "Candy"
        case .dusk: return "Dusk"
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
        case .magma: return 8
        case .ocean: return 9
        case .candy: return 10
        case .dusk: return 11
        }
    }

    static let highestShaderIndex: Float = 11
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
