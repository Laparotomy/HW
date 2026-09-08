import XCTest
@testable import VideoMapper

final class ProjectCodingTests: XCTestCase {

    /// Layer content is an enum with associated values; if its coding ever breaks,
    /// every saved show silently loses its media.
    func testProjectSurvivesRoundTrip() throws {
        var project = MappingProject(name: "Warehouse")
        let ref = MediaReference(kind: .video, filename: "clip.mov", displayName: "Clip",
                                 pixelSize: CGSize(width: 1920, height: 1080), duration: 12)
        var layer = MappingLayer.make(from: ref, canvasAspect: 16.0 / 9.0)
        layer.appearance.blendMode = .screen
        layer.appearance.texture.pattern = .dots
        layer.appearance.tint = RGBAColor(red: 0.2, green: 0.4, blue: 0.9)
        layer.transform.setCorner(3, to: CGPoint(x: 0.05, y: 0.95))
        layer.modulation = [ModulationRoute(source: .bass, target: .scale, amount: -0.4)]
        project.layers = [layer]
        project.audio.track = MediaReference(kind: .video, filename: "song.m4a",
                                             displayName: "Song", pixelSize: .zero, duration: 200)

        let data = try JSONEncoder().encode(project)
        let restored = try JSONDecoder().decode(MappingProject.self, from: data)

        XCTAssertEqual(restored.layers, project.layers)
        XCTAssertEqual(restored.audio, project.audio)
        XCTAssertEqual(restored.name, project.name)
        XCTAssertEqual(restored.canvasSize, project.canvasSize)
        XCTAssertEqual(restored.layers.first?.content.media?.filename, "clip.mov")
        XCTAssertEqual(restored.layers.first?.appearance.blendMode, .screen)
        XCTAssertEqual(restored.layers.first?.appearance.texture.pattern, .dots)
        XCTAssertTrue(restored.layers.first?.transform.isWarped == true)
        XCTAssertEqual(restored.layers.first?.modulation.first?.amount, -0.4)
    }

    func testReferencedMediaCoversLayersTextureAndTrack() {
        var project = MappingProject(name: "Show")
        let clip = MediaReference(kind: .video, filename: "a.mov", displayName: "A",
                                  pixelSize: .zero, duration: 1)
        let overlay = MediaReference(kind: .image, filename: "b.png", displayName: "B",
                                     pixelSize: .zero, duration: 0)
        var layer = MappingLayer(name: "L", content: .video(clip, VideoPlayback()))
        layer.appearance.texture.image = overlay
        project.layers = [layer]
        project.audio.track = MediaReference(kind: .video, filename: "c.m4a", displayName: "C",
                                             pixelSize: .zero, duration: 1)

        XCTAssertEqual(project.referencedMedia, ["a.mov", "b.png", "c.m4a"])
    }

    /// New layers must not distort their media: a 16:9 clip on a 16:9 canvas gets a
    /// square-on aspect, a portrait clip gets a narrow one.
    func testLayerFitPreservesAspect() {
        let landscape = MediaReference(kind: .video, filename: "l.mov", displayName: "L",
                                       pixelSize: CGSize(width: 1920, height: 1080), duration: 1)
        let layer = MappingLayer.make(from: landscape, canvasAspect: 16.0 / 9.0)
        XCTAssertEqual(layer.transform.size.width, 0.7, accuracy: 1e-6)
        XCTAssertEqual(layer.transform.size.height, 0.7, accuracy: 1e-6)

        let portrait = MediaReference(kind: .video, filename: "p.mov", displayName: "P",
                                      pixelSize: CGSize(width: 1080, height: 1920), duration: 1)
        let tall = MappingLayer.make(from: portrait, canvasAspect: 16.0 / 9.0)
        XCTAssertLessThan(tall.transform.size.width, tall.transform.size.height)
        // 9:16 media inside a 16:9 canvas occupies 0.7 * (9/16) / (16/9) of the width.
        XCTAssertEqual(tall.transform.size.width, 0.7 * (9.0 / 16.0) / (16.0 / 9.0), accuracy: 1e-6)
    }
}

final class ModulationTests: XCTestCase {

    private func features(bass: Double) -> AudioFeatures {
        var features = AudioFeatures()
        features.bass = bass
        return features
    }

    func testOffsetsAreAdditiveAndReversible() {
        let engine = ModulationEngine()
        var layer = MappingLayer(name: "L")
        layer.appearance.intensity = 1
        layer.modulation = [ModulationRoute(source: .bass, target: .intensity,
                                            amount: 0.5, smoothing: 0)]

        let loud = engine.offsets(for: layer, features: features(bass: 1),
                                  showTime: 0, fallbackBPM: 120)
        XCTAssertEqual(loud.intensity, 1.0, accuracy: 1e-9)
        XCTAssertEqual(engine.resolve(layer: layer, offsets: loud).appearance.intensity,
                       2.0, accuracy: 1e-9)

        // Silence returns the layer to exactly what was authored.
        let quiet = engine.offsets(for: layer, features: features(bass: 0),
                                   showTime: 0, fallbackBPM: 120)
        XCTAssertEqual(engine.resolve(layer: layer, offsets: quiet).appearance.intensity,
                       1.0, accuracy: 1e-9)
    }

    /// Smoothing must decay, not stick: a peak has to release between beats.
    func testSmoothingReleasesOverTime() {
        let engine = ModulationEngine()
        var layer = MappingLayer(name: "L")
        layer.modulation = [ModulationRoute(source: .bass, target: .opacity,
                                            amount: 1, smoothing: 0.5)]

        _ = engine.offsets(for: layer, features: features(bass: 1), showTime: 0, fallbackBPM: 120)
        let first = engine.offsets(for: layer, features: features(bass: 0), showTime: 0.1, fallbackBPM: 120)
        let second = engine.offsets(for: layer, features: features(bass: 0), showTime: 0.2, fallbackBPM: 120)
        XCTAssertEqual(first.opacity, 0.5, accuracy: 1e-9)
        XCTAssertLessThan(second.opacity, first.opacity)
    }

    func testResolvedValuesStayInRange() {
        let engine = ModulationEngine()
        var layer = MappingLayer(name: "L")
        layer.appearance.opacity = 0.9
        layer.modulation = [ModulationRoute(source: .level, target: .opacity,
                                            amount: 1, smoothing: 0)]
        var loud = AudioFeatures()
        loud.level = 1
        let offsets = engine.offsets(for: layer, features: loud, showTime: 0, fallbackBPM: 120)
        XCTAssertEqual(engine.resolve(layer: layer, offsets: offsets).appearance.opacity, 1.0)
    }

    /// With no analysable audio, a beat route still animates off the manual tempo,
    /// so a show can be programmed in silence.
    func testBeatRouteFallsBackToManualTempo() {
        let engine = ModulationEngine()
        var layer = MappingLayer(name: "L")
        layer.modulation = [ModulationRoute(source: .beat, target: .intensity,
                                            amount: 1, smoothing: 0)]
        let onBeat = engine.offsets(for: layer, features: AudioFeatures(),
                                    showTime: 0, fallbackBPM: 120)
        let offBeat = engine.offsets(for: layer, features: AudioFeatures(),
                                     showTime: 0.25, fallbackBPM: 120)
        XCTAssertGreaterThan(onBeat.intensity, offBeat.intensity)
    }
}

final class BeatTrackerTests: XCTestCase {
    func testTapTempoConvergesOnBPM() {
        let tracker = BeatTracker()
        let interval = 0.5   // 120 BPM
        for i in 0...8 {
            tracker.tap(at: Double(i) * interval)
        }
        XCTAssertEqual(tracker.bpm, 120, accuracy: 3)
    }

    func testTempoIsFoldedIntoMusicalRange() {
        let tracker = BeatTracker()
        // 0.3 s spacing is 200 BPM; it should fold to 100.
        for i in 0...8 { tracker.tap(at: Double(i) * 0.3) }
        XCTAssertGreaterThanOrEqual(tracker.bpm, 70)
        XCTAssertLessThanOrEqual(tracker.bpm, 180)
    }
}
