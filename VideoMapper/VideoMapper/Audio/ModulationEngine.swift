import CoreGraphics
import Foundation

/// Per-layer modulation offsets applied on top of stored values.
struct ModulationOffsets {
    var intensity: Double = 0
    var opacity: Double = 0
    var scale: Double = 0
    var tintAmount: Double = 0
    var textureAmount: Double = 0
    var rotation: Double = 0
}

/// Turns audio features into per-layer parameter offsets.
///
/// Offsets are additive rather than absolute so the stored project is never
/// overwritten by the music: stop the track and every layer springs back to
/// exactly what was authored.
final class ModulationEngine {
    /// Envelope state per route id, so smoothing survives across frames.
    private var envelopes: [UUID: Double] = [:]

    func reset() { envelopes.removeAll() }

    /// Drops state for routes that no longer exist.
    func prune(activeRouteIDs: Set<UUID>) {
        envelopes = envelopes.filter { activeRouteIDs.contains($0.key) }
    }

    func offsets(for layer: MappingLayer, features: AudioFeatures,
                 showTime: Double, fallbackBPM: Double) -> ModulationOffsets {
        var offsets = ModulationOffsets()
        for route in layer.modulation where route.source != .none {
            var value = features.value(for: route.source)

            // With no analysable audio, a beat route still runs off the manual tempo
            // so a show can be programmed and rehearsed in silence.
            if route.source == .beat, features.bpm == 0, fallbackBPM > 0 {
                let period = 60.0 / fallbackBPM
                let phase = (showTime / period).truncatingRemainder(dividingBy: 1)
                value = pow(1 - phase, 2)
            }

            let smoothing = min(max(route.smoothing, 0), 0.99)
            let previous = envelopes[route.id] ?? 0
            // Rise immediately, fall at the smoothing rate.
            let smoothed = value > previous ? value : previous * smoothing + value * (1 - smoothing)
            envelopes[route.id] = smoothed

            let delta = smoothed * route.amount
            switch route.target {
            case .intensity: offsets.intensity += delta * 2
            case .opacity: offsets.opacity += delta
            case .scale: offsets.scale += delta * 0.5
            case .tintAmount: offsets.tintAmount += delta
            case .textureAmount: offsets.textureAmount += delta
            case .rotation: offsets.rotation += delta * .pi / 4
            }
        }
        return offsets
    }

    /// Applies offsets and clamps everything into a drawable range.
    func resolve(layer: MappingLayer, offsets: ModulationOffsets) -> ResolvedLayer {
        var appearance = layer.appearance
        appearance.intensity = max(0, appearance.intensity + offsets.intensity)
        appearance.opacity = min(1, max(0, appearance.opacity + offsets.opacity))
        appearance.tintAmount = min(1, max(0, appearance.tintAmount + offsets.tintAmount))
        appearance.texture.amount = min(1, max(0, appearance.texture.amount + offsets.textureAmount))

        var transform = layer.transform
        transform.rotation += offsets.rotation
        let scale = max(0.01, 1 + offsets.scale)

        return ResolvedLayer(id: layer.id,
                             quad: transform.quad(scale: scale),
                             appearance: appearance,
                             content: layer.content)
    }
}
