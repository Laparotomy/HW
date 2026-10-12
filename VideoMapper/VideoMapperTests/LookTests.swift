import Combine
import XCTest
@testable import VideoMapper

/// The contracts between Swift and the shader, and between Swift and the saved file.
///
/// Both fail the same way: silently. A shader index that drifts draws the wrong blend
/// or the wrong overlay with no error anywhere, and a raw value that changes throws
/// away that part of every show ever saved. Neither is caught by building.
final class ShaderContractTests: XCTestCase {

    func testBlendModesAreContiguousFromZero() {
        let indices = BlendMode.allCases.map(\.shaderIndex).sorted()
        XCTAssertEqual(indices, (0..<BlendMode.allCases.count).map(Float.init))
    }

    /// The shader's `patternValue` switch covers 1...5 and handles `none` and a
    /// custom image outside it, so the indices have to run 0...6 with nothing spare.
    func testTexturePatternsAreContiguousFromZero() {
        let indices = TexturePattern.allCases.map(\.shaderIndex).sorted()
        XCTAssertEqual(indices, (0..<TexturePattern.allCases.count).map(Float.init))
        XCTAssertEqual(TexturePattern.none.shaderIndex, 0)
        // `custom` is the one the shader answers with a texture rather than a formula,
        // so it has to be last — past everything the switch draws itself.
        XCTAssertEqual(TexturePattern.custom.shaderIndex,
                       Float(TexturePattern.allCases.count - 1))
    }

    /// Raw values are the file format. Renaming a case silently drops that field from
    /// every show already saved, which is worse than failing to decode.
    func testEveryPersistedRawValueIsPinned() {
        XCTAssertEqual(BlendMode.allCases.map(\.rawValue),
                       ["normal", "add", "screen", "multiply"])
        XCTAssertEqual(TexturePattern.allCases.map(\.rawValue),
                       ["none", "stripes", "grid", "dots", "noise", "scanlines", "custom"])
        XCTAssertEqual(ModulationSource.allCases.map(\.rawValue),
                       ["none", "level", "bass", "mid", "treble", "beat"])
        XCTAssertEqual(ModulationTarget.allCases.map(\.rawValue),
                       ["intensity", "opacity", "scale", "tintAmount", "textureAmount", "rotation"])
        XCTAssertEqual(ClockSource.allCases.map(\.rawValue), ["freeRun", "track", "listen"])
        XCTAssertEqual(TempoMode.allCases.map(\.rawValue), ["automatic", "manual"])
    }

    /// Adding a generator or a palette is additive; renaming one is not, for the same
    /// reason. These are the names inside every saved show that uses them.
    func testGeneratorAndPaletteRawValuesAreStable() {
        for kind in GeneratorKind.allCases {
            XCTAssertEqual(kind.rawValue, kind.rawValue.lowercased(), "\(kind)")
            XCTAssertFalse(kind.rawValue.contains(" "), "\(kind)")
        }
        XCTAssertTrue(GeneratorKind.allCases.map(\.rawValue).contains("plasma"))
        XCTAssertTrue(GeneratorPalette.allCases.map(\.rawValue).contains("mono"))
    }

    /// Everything the pickers list needs a label, and two things sharing one are
    /// indistinguishable in a menu.
    func testEveryPickerEntryIsLabelledDistinctly() {
        XCTAssertEqual(Set(BlendMode.allCases.map(\.displayName)).count, BlendMode.allCases.count)
        XCTAssertEqual(Set(TexturePattern.allCases.map(\.displayName)).count,
                       TexturePattern.allCases.count)
        XCTAssertEqual(Set(ModulationSource.allCases.map(\.displayName)).count,
                       ModulationSource.allCases.count)
        XCTAssertEqual(Set(ModulationTarget.allCases.map(\.displayName)).count,
                       ModulationTarget.allCases.count)
        XCTAssertEqual(Set(ClockSource.allCases.map(\.displayName)).count,
                       ClockSource.allCases.count)
    }
}

final class ColourTests: XCTestCase {

    func testComponentsReachTheShaderInOrder() {
        let colour = RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        XCTAssertEqual(colour.simd.x, 0.1, accuracy: 1e-6)
        XCTAssertEqual(colour.simd.y, 0.2, accuracy: 1e-6)
        XCTAssertEqual(colour.simd.z, 0.3, accuracy: 1e-6)
        XCTAssertEqual(colour.simd.w, 0.4, accuracy: 1e-6)
    }

    func testTheConstantsAreWhatTheyClaim() {
        XCTAssertEqual(RGBAColor.white, RGBAColor(red: 1, green: 1, blue: 1, alpha: 1))
        XCTAssertEqual(RGBAColor.black, RGBAColor(red: 0, green: 0, blue: 0, alpha: 1))
        // Opaque, not transparent: a transparent black background would let whatever
        // is behind the renderer show through on the projector.
        XCTAssertEqual(RGBAColor.black.alpha, 1)
    }

    func testAlphaDefaultsToOpaque() {
        XCTAssertEqual(RGBAColor(red: 0.5, green: 0.5, blue: 0.5).alpha, 1)
    }

    func testAColourRoundTrips() throws {
        let colour = RGBAColor(red: 0.35, green: 0.55, blue: 1, alpha: 0.75)
        let decoded = try JSONDecoder().decode(RGBAColor.self,
                                               from: JSONEncoder().encode(colour))
        XCTAssertEqual(decoded, colour)
    }
}

final class AppearancePersistenceTests: XCTestCase {

    /// A new layer must draw its content unchanged. Anything else means importing a
    /// clip and seeing something that is not the clip.
    func testDefaultsAreATransparentPassThrough() {
        let appearance = Appearance()
        XCTAssertEqual(appearance.opacity, 1)
        XCTAssertEqual(appearance.intensity, 1)
        XCTAssertEqual(appearance.tintAmount, 0)
        XCTAssertEqual(appearance.saturation, 1)
        XCTAssertEqual(appearance.contrast, 1)
        XCTAssertEqual(appearance.feather, 0)
        XCTAssertEqual(appearance.blendMode, .normal)
        XCTAssertEqual(appearance.texture.pattern, TexturePattern.none)
        XCTAssertNil(appearance.texture.image)
    }

    func testEveryLookFieldSurvivesASaveAndReopen() throws {
        var appearance = Appearance()
        appearance.opacity = 0.62
        appearance.intensity = 2.5
        appearance.tint = RGBAColor(red: 0.2, green: 0.4, blue: 0.9)
        appearance.tintAmount = 0.75
        appearance.saturation = 1.4
        appearance.contrast = 0.8
        appearance.blendMode = .screen
        appearance.feather = 0.25
        appearance.texture.pattern = .custom
        appearance.texture.scale = 12
        appearance.texture.amount = 0.4
        appearance.texture.scrollX = -0.5
        appearance.texture.scrollY = 0.25
        appearance.texture.image = MediaReference(kind: .image, filename: "t.png",
                                                  displayName: "T", pixelSize: .zero)

        let decoded = try JSONDecoder().decode(Appearance.self,
                                               from: JSONEncoder().encode(appearance))
        XCTAssertEqual(decoded, appearance)
        XCTAssertEqual(decoded.texture.image?.filename, "t.png")
    }

    /// A colour layer is created tinted white at full mix so its swatch is visible.
    func testAColourLayerIsBornVisible() {
        let layer = MappingLayer(name: "Wash")
        XCTAssertEqual(layer.appearance.tintAmount, 1)
        XCTAssertEqual(layer.appearance.tint, RGBAColor.white)
        XCTAssertTrue(layer.content.isSolid)
    }
}

/// Modulation state is held per route and per layer across frames. It has to be
/// dropped when the route or the layer goes, or a deleted layer's envelope keeps
/// feeding whatever reuses its slot.
final class ModulationStateTests: XCTestCase {

    private func features(bass: Double) -> AudioFeatures {
        var features = AudioFeatures()
        features.bass = bass
        return features
    }

    private func layer(route: ModulationRoute) -> MappingLayer {
        var layer = MappingLayer(name: "Driven")
        layer.modulation = [route]
        return layer
    }

    func testAnEnvelopeSurvivesBetweenFramesAndFallsWhenTheSoundStops() {
        let engine = ModulationEngine()
        let route = ModulationRoute(source: .bass, target: .intensity,
                                    amount: 1, smoothing: 0.8)
        let driven = layer(route: route)

        let loud = engine.offsets(for: driven, features: features(bass: 1),
                                  showTime: 0, fallbackBPM: 120)
        let silent = engine.offsets(for: driven, features: features(bass: 0),
                                    showTime: 0.1, fallbackBPM: 120)

        XCTAssertGreaterThan(loud.intensity, 0)
        // It decays rather than snapping off — that is the whole point of smoothing.
        XCTAssertLessThan(silent.intensity, loud.intensity)
        XCTAssertGreaterThan(silent.intensity, 0)
    }

    func testResetForgetsEverything() {
        let engine = ModulationEngine()
        let driven = layer(route: ModulationRoute(source: .bass, target: .intensity,
                                                  amount: 1, smoothing: 0.9))
        _ = engine.offsets(for: driven, features: features(bass: 1),
                           showTime: 0, fallbackBPM: 120)
        engine.reset()

        let afterReset = engine.offsets(for: driven, features: features(bass: 0),
                                        showTime: 0.1, fallbackBPM: 120)
        XCTAssertEqual(afterReset.intensity, 0, accuracy: 1e-12)
    }

    func testPruningDropsARouteThatIsGone() {
        let engine = ModulationEngine()
        let route = ModulationRoute(source: .bass, target: .intensity,
                                    amount: 1, smoothing: 0.9)
        let driven = layer(route: route)
        _ = engine.offsets(for: driven, features: features(bass: 1),
                           showTime: 0, fallbackBPM: 120)

        engine.prune(activeRouteIDs: [])
        let afterPrune = engine.offsets(for: driven, features: features(bass: 0),
                                        showTime: 0.1, fallbackBPM: 120)
        XCTAssertEqual(afterPrune.intensity, 0, accuracy: 1e-12)
    }

    func testPruningKeepsARouteThatIsStillThere() {
        let engine = ModulationEngine()
        let route = ModulationRoute(source: .bass, target: .intensity,
                                    amount: 1, smoothing: 0.9)
        let driven = layer(route: route)
        _ = engine.offsets(for: driven, features: features(bass: 1),
                           showTime: 0, fallbackBPM: 120)

        engine.prune(activeRouteIDs: [route.id])
        let afterPrune = engine.offsets(for: driven, features: features(bass: 0),
                                        showTime: 0.1, fallbackBPM: 120)
        XCTAssertGreaterThan(afterPrune.intensity, 0)
    }

    /// A generator's own reactivity is keyed by layer, not by route.
    func testAGeneratorDriveRisesWithTheMusicAndIsBoundedByItsAmount() {
        let engine = ModulationEngine()
        var settings = GeneratorKind.plasma.defaultSettings
        settings.audioSource = .bass
        settings.audioAmount = 0.5
        let driven = MappingLayer(name: "P", content: .generator(.plasma, settings))

        let offsets = engine.offsets(for: driven, features: features(bass: 1),
                                     showTime: 0, fallbackBPM: 120)
        XCTAssertGreaterThan(offsets.generatorDrive, 0)
        XCTAssertLessThanOrEqual(offsets.generatorDrive, 0.5)
    }

    func testASourceWithNoAudioRoutingIsNotDriven() {
        let engine = ModulationEngine()
        var settings = GeneratorKind.plasma.defaultSettings
        settings.audioSource = .none
        let quiet = MappingLayer(name: "P", content: .generator(.plasma, settings))

        let offsets = engine.offsets(for: quiet, features: features(bass: 1),
                                     showTime: 0, fallbackBPM: 120)
        XCTAssertEqual(offsets.generatorDrive, 0, accuracy: 1e-12)
    }

    func testAMediaLayerHasNoGeneratorDrive() {
        let engine = ModulationEngine()
        let offsets = engine.offsets(for: MappingLayer(name: "Solid"),
                                     features: features(bass: 1),
                                     showTime: 0, fallbackBPM: 120)
        XCTAssertEqual(offsets.generatorDrive, 0, accuracy: 1e-12)
    }

    /// Modulating rotation must turn the drawn quad, not just report a number.
    func testRotationModulationReachesTheDrawnQuad() {
        let engine = ModulationEngine()
        var still = MappingLayer(name: "Turner")
        still.transform.size = CGSize(width: 0.5, height: 0.5)

        var offsets = ModulationOffsets()
        offsets.rotation = .pi / 4
        let turned = engine.resolve(layer: still, offsets: offsets)
        let flat = engine.resolve(layer: still, offsets: ModulationOffsets())

        XCTAssertNotEqual(turned.quad.p00, flat.quad.p00)
        // And the stored project is untouched: offsets are additive, never written back.
        XCTAssertEqual(still.transform.rotation, 0)
    }

    /// Clamping is what stops a loud passage pushing opacity past 1 and staying there.
    func testResolvedValuesAreClampedIntoADrawableRange() {
        let engine = ModulationEngine()
        var loud = MappingLayer(name: "Loud")
        loud.appearance.opacity = 0.9
        loud.appearance.tintAmount = 0.9
        loud.appearance.texture.amount = 0.9

        var offsets = ModulationOffsets()
        offsets.opacity = 5
        offsets.tintAmount = 5
        offsets.textureAmount = 5
        offsets.intensity = -99
        offsets.scale = -99

        let resolved = engine.resolve(layer: loud, offsets: offsets)
        XCTAssertEqual(resolved.appearance.opacity, 1)
        XCTAssertEqual(resolved.appearance.tintAmount, 1)
        XCTAssertEqual(resolved.appearance.texture.amount, 1)
        XCTAssertEqual(resolved.appearance.intensity, 0)
        // A layer scaled to nothing would vanish and could not be got back by ear.
        XCTAssertFalse(resolved.quad.p00.x.isNaN)
        XCTAssertTrue(resolved.quad.p00.x.isFinite)
    }
}

/// Previews are asked for from inside `body`.
///
/// SwiftUI forbids publishing a change during a view update — "this will cause
/// undefined behavior" — and it only says so at runtime, when a view that trips it is
/// actually on screen. A build cannot catch it and neither can a smoke launch that
/// never opens the offending screen, so it has to be caught here.
@MainActor
final class ThumbnailPublishingTests: XCTestCase {

    func testAskingForAPreviewDuringAViewUpdatePublishesNothing() {
        let store = ContentThumbnailStore.shared
        var published = 0
        let token = store.objectWillChange.sink { _ in published += 1 }
        defer { token.cancel() }

        let projectID = UUID()
        _ = store.image(for: .solid, projectID: projectID)
        // Every kind, because the generator branch is the one that used to write its
        // result straight into the published dictionary.
        for kind in GeneratorKind.allCases {
            _ = store.image(for: .generator(kind, kind.defaultSettings), projectID: projectID)
        }

        XCTAssertEqual(published, 0, "image(for:projectID:) published during a view update")
    }

    /// Asking twice has to give the same answer, or a layer's preview would flicker
    /// between two renders of the same thing.
    func testTheSameContentAnswersTheSameWayTwice() {
        let store = ContentThumbnailStore.shared
        let projectID = UUID()
        let content = LayerContent.generator(.plasma, GeneratorKind.plasma.defaultSettings)

        let first = store.image(for: content, projectID: projectID)
        let second = store.image(for: content, projectID: projectID)
        // Either both nil (no Metal device on this host) or the identical image.
        XCTAssertEqual(first == nil, second == nil)
        if let first, let second {
            XCTAssertEqual(first.width, second.width)
            XCTAssertEqual(first.height, second.height)
        }
    }

    /// A colour layer has nothing to preview, and must not be given a cache slot.
    func testAColourLayerHasNoSignatureAndNoPreview() {
        XCTAssertNil(ContentThumbnailStore.signature(for: .solid))
        XCTAssertNil(ContentThumbnailStore.shared.image(for: .solid, projectID: UUID()))
    }

    /// The palette is part of the key: recolour a source and the preview has to
    /// follow it rather than serve the old render.
    func testTheSignatureFollowsTheGeneratorPalette() {
        var warm = GeneratorKind.plasma.defaultSettings
        warm.palette = .ember
        var cold = warm
        cold.palette = .ice

        let warmKey = ContentThumbnailStore.signature(for: .generator(.plasma, warm))
        let coldKey = ContentThumbnailStore.signature(for: .generator(.plasma, cold))
        XCTAssertNotNil(warmKey)
        XCTAssertNotEqual(warmKey, coldKey)
    }

    /// Two layers showing the same clip share one decode; a clip and a still with the
    /// same filename do not, because they are decoded by different paths.
    func testMediaSignaturesAreKeyedByFileAndKind() {
        let ref = MediaReference(kind: .video, filename: "clip.mov", displayName: "Clip",
                                 pixelSize: .zero, duration: 3)
        let asVideo = ContentThumbnailStore.signature(for: .video(ref, VideoPlayback()))
        let asImage = ContentThumbnailStore.signature(for: .image(ref))
        XCTAssertNotEqual(asVideo, asImage)

        // Same file, different layer: one key, so it is decoded once.
        var slower = VideoPlayback()
        slower.rate = 0.5
        XCTAssertEqual(asVideo, ContentThumbnailStore.signature(for: .video(ref, slower)))
    }
}
