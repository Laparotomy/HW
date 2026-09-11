import XCTest
@testable import VideoMapper

/// The generator library is mostly shader code, which no unit test can execute.
/// What these cover is the contract between Swift and MSL — the indices, the ranges
/// and the persistence — because a mismatch there draws the wrong pattern silently
/// rather than failing to build.
final class GeneratorLibraryTests: XCTestCase {

    func testEveryKindHasADistinctShaderIndex() {
        let indices = GeneratorKind.allCases.map(\.shaderIndex)
        XCTAssertEqual(Set(indices).count, GeneratorKind.allCases.count)
    }

    /// Zero is the shader's "this layer is media-backed" sentinel, so no generator
    /// may claim it, and the dispatch switch only covers 1...12.
    func testShaderIndicesAreInsideTheDispatchRange() {
        for kind in GeneratorKind.allCases {
            XCTAssertGreaterThanOrEqual(kind.shaderIndex, 1, "\(kind.rawValue)")
            XCTAssertLessThanOrEqual(kind.shaderIndex, 12, "\(kind.rawValue)")
        }
    }

    func testEveryPaletteHasADistinctShaderIndex() {
        let indices = GeneratorPalette.allCases.map(\.shaderIndex)
        XCTAssertEqual(Set(indices).count, GeneratorPalette.allCases.count)
        for index in indices {
            XCTAssertGreaterThanOrEqual(index, 0)
            XCTAssertLessThanOrEqual(index, 7)
        }
    }

    func testEveryKindIsDescribedForTheBrowser() {
        for kind in GeneratorKind.allCases {
            XCTAssertFalse(kind.displayName.isEmpty, "\(kind.rawValue)")
            XCTAssertFalse(kind.detail.isEmpty, "\(kind.rawValue)")
            XCTAssertFalse(kind.symbolName.isEmpty, "\(kind.rawValue)")
        }
    }

    /// Defaults are what the browser renders and what a new layer gets, so a value
    /// outside the slider's range would show a control that cannot return to it.
    func testDefaultSettingsSurviveClamping() {
        for kind in GeneratorKind.allCases {
            let defaults = kind.defaultSettings
            XCTAssertEqual(defaults, defaults.clamped(), "\(kind.rawValue)")
        }
    }

    func testDefaultSpeedIsNonZeroSoASourceMoves() {
        for kind in GeneratorKind.allCases {
            XCTAssertGreaterThan(kind.defaultSettings.speed, 0, "\(kind.rawValue)")
        }
    }

    func testClampingPullsValuesIntoRange() {
        var settings = GeneratorSettings()
        settings.speed = 99
        settings.scale = -4
        settings.complexity = 3
        settings.audioAmount = -1
        settings.variation = 1000

        let clamped = settings.clamped()
        XCTAssertEqual(clamped.speed, GeneratorSettings.speedRange.upperBound)
        XCTAssertEqual(clamped.scale, GeneratorSettings.scaleRange.lowerBound)
        XCTAssertEqual(clamped.complexity, GeneratorSettings.complexityRange.upperBound)
        XCTAssertEqual(clamped.audioAmount, 0)
        XCTAssertEqual(clamped.variation, GeneratorSettings.variationRange.upperBound)
    }

    func testClampingLeavesAValidSettingAlone() {
        let settings = GeneratorSettings(speed: 0.4, scale: 4, complexity: 0.5,
                                         palette: .ice, audioSource: .bass,
                                         audioAmount: 0.5, variation: 2)
        XCTAssertEqual(settings.clamped(), settings)
    }
}

final class GeneratorLayerTests: XCTestCase {

    func testAGeneratorLayerFillsTheCanvas() {
        let layer = MappingLayer.make(generator: .plasma)
        XCTAssertEqual(layer.transform.size, CGSize(width: 1, height: 1))
        XCTAssertEqual(layer.transform.center, CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(layer.name, GeneratorKind.plasma.displayName)
    }

    /// Generators carry no media. That is what lets a follower device reproduce the
    /// layer exactly without a single byte being transferred.
    func testAGeneratorLayerReferencesNoMedia() {
        let layer = MappingLayer.make(generator: .tunnel)
        XCTAssertNil(layer.content.media)
        XCTAssertFalse(layer.content.isVideo)
    }

    func testTheGeneratorAccessorReturnsKindAndSettings() {
        let layer = MappingLayer.make(generator: .cells)
        let generator = layer.content.generator
        XCTAssertEqual(generator?.kind, .cells)
        XCTAssertEqual(generator?.settings, GeneratorKind.cells.defaultSettings)
    }

    func testMediaLayersReportNoGenerator() {
        XCTAssertNil(LayerContent.solid.generator)
        let ref = MediaReference(kind: .image, filename: "a.png", displayName: "a",
                                 pixelSize: CGSize(width: 10, height: 10))
        XCTAssertNil(LayerContent.image(ref).generator)
    }

    func testContentDisplayNameUsesTheGeneratorName() {
        let content = LayerContent.generator(.aurora, GeneratorKind.aurora.defaultSettings)
        XCTAssertEqual(content.displayName, "Aurora")
    }
}

final class GeneratorPersistenceTests: XCTestCase {

    /// A show made of generators has to survive a save/load and a sync broadcast,
    /// both of which go through Codable.
    func testAGeneratorLayerRoundTripsThroughCodable() throws {
        var settings = GeneratorKind.kaleidoscope.defaultSettings
        settings.palette = .toxic
        settings.audioSource = .treble
        settings.variation = 3.5

        var project = MappingProject(name: "Generators")
        project.layers = [MappingLayer(name: "K", content: .generator(.kaleidoscope, settings))]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MappingProject.self, from: data)

        // Compared layer-wise, like the other project tests: Date round-tripping
        // through JSON is not bit-exact, so the whole-struct compare is flaky.
        XCTAssertEqual(decoded.layers, project.layers)
        let generator = decoded.layers.first?.content.generator
        XCTAssertEqual(generator?.kind, .kaleidoscope)
        XCTAssertEqual(generator?.settings, settings)
    }

    /// Adding the generator case must not have disturbed the existing ones: a show
    /// saved before this feature existed still has to open.
    func testMediaLayersStillRoundTrip() throws {
        let ref = MediaReference(kind: .video, filename: "clip.mov", displayName: "Clip",
                                 pixelSize: CGSize(width: 1920, height: 1080), duration: 12)
        var project = MappingProject(name: "Mixed")
        project.layers = [
            MappingLayer(name: "Solid"),
            MappingLayer(name: "Clip", content: .video(ref, VideoPlayback())),
            MappingLayer.make(generator: .waves)
        ]

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(MappingProject.self, from: data)
        XCTAssertEqual(decoded.layers, project.layers)
    }

    /// Kinds and palettes are stored by name, so renaming a raw value would silently
    /// turn saved shows into something else.
    func testRawValuesAreStable() {
        XCTAssertEqual(GeneratorKind.plasma.rawValue, "plasma")
        XCTAssertEqual(GeneratorKind.metaballs.rawValue, "metaballs")
        XCTAssertEqual(GeneratorPalette.mono.rawValue, "mono")
        XCTAssertEqual(GeneratorPalette.mist.rawValue, "mist")
    }

    func testEveryKindDecodesFromItsRawValue() throws {
        // Wrapped in an array: a bare enum is a JSON fragment, which is a separate
        // encoder capability and not what production code ever asks for.
        let data = try JSONEncoder().encode(GeneratorKind.allCases)
        let decoded = try JSONDecoder().decode([GeneratorKind].self, from: data)
        XCTAssertEqual(decoded, GeneratorKind.allCases)
    }
}

final class GeneratorModulationTests: XCTestCase {

    func testAGeneratorWithNoAudioSourceIsNotDriven() {
        let engine = ModulationEngine()
        let layer = MappingLayer.make(generator: .plasma)
        let offsets = engine.offsets(for: layer, features: AudioFeatures(),
                                     showTime: 1, fallbackBPM: 120)
        XCTAssertEqual(offsets.generatorDrive, 0)
    }

    func testAMediaLayerIsNeverDriven() {
        let engine = ModulationEngine()
        let layer = MappingLayer(name: "Colour")
        let offsets = engine.offsets(for: layer, features: AudioFeatures(),
                                     showTime: 1, fallbackBPM: 120)
        XCTAssertEqual(offsets.generatorDrive, 0)
    }

    /// With no analysable audio a beat-driven generator still pulses off the manual
    /// tempo, so a strobe can be programmed in a silent room.
    func testABeatDrivenGeneratorRunsOffTheManualTempo() {
        let engine = ModulationEngine()
        var settings = GeneratorKind.strobe.defaultSettings
        settings.audioSource = .beat
        settings.audioAmount = 1
        let layer = MappingLayer(name: "Strobe", content: .generator(.strobe, settings))

        // Right on a beat at 120 BPM (period 0.5s) the envelope is at its peak.
        let onBeat = engine.offsets(for: layer, features: AudioFeatures(),
                                    showTime: 0, fallbackBPM: 120)
        XCTAssertGreaterThan(onBeat.generatorDrive, 0.9)
    }

    func testDriveIsScaledByDepthAndStaysInRange() {
        let engine = ModulationEngine()
        var settings = GeneratorKind.strobe.defaultSettings
        settings.audioSource = .beat
        settings.audioAmount = 0.25
        let layer = MappingLayer(name: "Strobe", content: .generator(.strobe, settings))

        let offsets = engine.offsets(for: layer, features: AudioFeatures(),
                                     showTime: 0, fallbackBPM: 120)
        XCTAssertLessThanOrEqual(offsets.generatorDrive, 0.25)
        XCTAssertGreaterThanOrEqual(offsets.generatorDrive, 0)
    }

    func testResolvedLayersCarryTheDriveToTheShader() {
        let engine = ModulationEngine()
        var settings = GeneratorKind.rings.defaultSettings
        settings.audioSource = .beat
        settings.audioAmount = 1
        let layer = MappingLayer(name: "Rings", content: .generator(.rings, settings))

        let offsets = engine.offsets(for: layer, features: AudioFeatures(),
                                     showTime: 0, fallbackBPM: 120)
        let resolved = engine.resolve(layer: layer, offsets: offsets)
        XCTAssertEqual(resolved.generatorDrive, offsets.generatorDrive)
    }

    /// A layer that stops being a generator must not leave its envelope behind.
    func testTheEnvelopeIsReleasedWhenAGeneratorGoesAway() {
        let engine = ModulationEngine()
        var settings = GeneratorKind.strobe.defaultSettings
        settings.audioSource = .beat
        settings.audioAmount = 1
        var layer = MappingLayer(name: "Strobe", content: .generator(.strobe, settings))

        _ = engine.offsets(for: layer, features: AudioFeatures(),
                           showTime: 0, fallbackBPM: 120)

        layer.content = .solid
        let after = engine.offsets(for: layer, features: AudioFeatures(),
                                   showTime: 0.25, fallbackBPM: 120)
        XCTAssertEqual(after.generatorDrive, 0)
    }
}
