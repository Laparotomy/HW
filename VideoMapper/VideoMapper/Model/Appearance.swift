import SwiftUI
import UIKit

/// Codable colour storage. `SwiftUI.Color` is not usefully Codable, so projects
/// persist raw components and convert on demand.
struct RGBAColor: Codable, Equatable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let white = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    var simd: SIMD4<Float> { SIMD4(Float(red), Float(green), Float(blue), Float(alpha)) }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }

    init(_ color: Color) {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }
}

/// How a layer is combined with the layers beneath it.
///
/// These map onto Metal blend factors rather than a compositing pass, so stacking
/// layers stays cheap enough for a 60 fps preview on device.
enum BlendMode: String, Codable, CaseIterable, Identifiable {
    case normal, add, screen, multiply

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .normal: return "Normal"
        case .add: return "Add"
        case .screen: return "Screen"
        case .multiply: return "Multiply"
        }
    }

    /// Index handed to the fragment shader so it can pre-multiply appropriately.
    var shaderIndex: Float {
        switch self {
        case .normal: return 0
        case .add: return 1
        case .screen: return 2
        case .multiply: return 3
        }
    }
}

/// Procedural overlay patterns, generated in the shader so a project stays
/// self-contained (no bundled texture assets to lose when a project is shared).
enum TexturePattern: String, Codable, CaseIterable, Identifiable {
    case none, stripes, grid, dots, noise, scanlines, custom

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .none: return "None"
        case .stripes: return "Stripes"
        case .grid: return "Grid"
        case .dots: return "Dots"
        case .noise: return "Noise"
        case .scanlines: return "Scanlines"
        case .custom: return "Image"
        }
    }

    var shaderIndex: Float {
        switch self {
        case .none: return 0
        case .stripes: return 1
        case .grid: return 2
        case .dots: return 3
        case .noise: return 4
        case .scanlines: return 5
        case .custom: return 6
        }
    }
}

/// Texture overlay settings for a layer.
struct TextureSettings: Codable, Equatable {
    var pattern: TexturePattern = .none
    /// Tiling repeats across the layer.
    var scale: Double = 8
    /// Dry/wet mix of the overlay, 0...1.
    var amount: Double = 0.5
    /// Scroll rate in tiles per second, animated off the show clock.
    var scrollX: Double = 0
    var scrollY: Double = 0
    /// Image used when `pattern == .custom`.
    var image: MediaReference?
}

/// Everything about how a layer looks that is not its shape.
struct Appearance: Codable, Equatable {
    var opacity: Double = 1
    /// Output gain. Above 1 this blows out highlights, which is what you want
    /// for projection onto dark surfaces.
    var intensity: Double = 1
    var tint: RGBAColor = .white
    /// How far the source colour is pushed toward `tint`, 0...1.
    var tintAmount: Double = 0
    var saturation: Double = 1
    var contrast: Double = 1
    var blendMode: BlendMode = .normal
    /// Soft edge width in UV units; essential for edge-blending adjacent projections.
    var feather: Double = 0
    var texture: TextureSettings = TextureSettings()
}
