#include <metal_stdlib>
using namespace metal;

// Layout must stay in sync with `LayerUniforms` in MetalRenderer.swift.
// Everything is packed into float4s so Swift and MSL agree on alignment without
// a bridging header.
struct LayerUniforms {
    float3x3 homography;   // unit square -> canvas quad, acts on (u, v, 1)
    float4 tint;           // rgba
    float4 params0;        // intensity, opacity, saturation, contrast
    float4 params1;        // tintAmount, feather, textureAmount, textureScale
    float4 params2;        // patternIndex, blendIndex, showTime, hasCustomTexture
    float4 params3;        // scrollX, scrollY, canvasAspect, unused
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

// Draws a unit-square triangle strip warped by the homography.
//
// The homogeneous coordinate `w` is written into `position.w` rather than divided
// out here, which is what makes the rasterizer interpolate `uv` with perspective
// correction. Without it a keystoned quad shows the classic "folded triangle" seam.
vertex VertexOut layer_vertex(uint vid [[vertex_id]],
                              constant LayerUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(1, 1) };
    float2 uv = corners[vid];

    float3 p = u.homography * float3(uv, 1.0);

    // Canvas space is (0..1, y down); clip space is (-1..1, y up).
    // clip.xy = (2x - w, w - 2y) so that after the divide we land on (2u-1, 1-2v).
    VertexOut out;
    out.position = float4(2.0 * p.x - p.z, p.z - 2.0 * p.y, 0.0, p.z);
    out.uv = uv;
    return out;
}

// Cheap hash-based value noise; deterministic so every device in an ensemble
// generates an identical pattern for the same show time.
static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float valueNoise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 w = f * f * (3.0 - 2.0 * f);
    float a = hash21(i);
    float b = hash21(i + float2(1, 0));
    float c = hash21(i + float2(0, 1));
    float d = hash21(i + float2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Returns the overlay pattern value in 0...1 for the given tiled coordinate.
static float patternValue(int index, float2 t, float time) {
    switch (index) {
        case 1: // stripes
            return step(0.5, fract(t.x));
        case 2: // grid
            return max(smoothstep(0.92, 1.0, fract(t.x)) + smoothstep(0.92, 1.0, fract(t.y)),
                       smoothstep(0.92, 1.0, 1.0 - fract(t.x)) + smoothstep(0.92, 1.0, 1.0 - fract(t.y)));
        case 3: { // dots
            float2 f = fract(t) - 0.5;
            return 1.0 - smoothstep(0.22, 0.30, length(f));
        }
        case 4: // noise
            return valueNoise(t + time * 0.25);
        case 5: // scanlines
            return 0.5 + 0.5 * sin(t.y * 6.2831853);
        default:
            return 0.0;
    }
}

fragment float4 layer_fragment(VertexOut in [[stage_in]],
                               constant LayerUniforms &u [[buffer(0)]],
                               texture2d<float> source [[texture(0)]],
                               texture2d<float> overlay [[texture(1)]],
                               sampler samp [[sampler(0)]]) {
    float4 color = source.sample(samp, in.uv);

    float intensity   = u.params0.x;
    float opacity     = u.params0.y;
    float saturation  = u.params0.z;
    float contrast    = u.params0.w;
    float tintAmount  = u.params1.x;
    float feather     = u.params1.y;
    float texAmount   = u.params1.z;
    float texScale    = max(u.params1.w, 0.0001);
    int   pattern     = int(u.params2.x + 0.5);
    int   blendIndex  = int(u.params2.y + 0.5);
    float showTime    = u.params2.z;
    bool  hasCustomTexture = u.params2.w > 0.5;
    float aspect      = max(u.params3.z, 0.0001);

    float3 rgb = color.rgb;

    // Saturation about Rec. 709 luma, then contrast about mid grey.
    float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
    rgb = mix(float3(luma), rgb, saturation);
    rgb = (rgb - 0.5) * contrast + 0.5;

    // Colour: push toward the tint, and always scale by the tint's own value so a
    // dimmed swatch dims the layer (matters for solid-colour wash layers).
    rgb = mix(rgb, rgb * u.tint.rgb, tintAmount);

    // Texture overlay. The tiling coordinate is aspect-corrected so squares stay
    // square on a 16:9 canvas, and scrolls off the shared show clock.
    if (pattern > 0 && texAmount > 0.0) {
        float2 t = float2(in.uv.x * aspect, in.uv.y) * texScale;
        t += float2(u.params3.x, u.params3.y) * showTime;
        float value;
        if (pattern == 6) {
            value = hasCustomTexture ? dot(overlay.sample(samp, fract(t)).rgb, float3(1.0 / 3.0)) : 1.0;
        } else {
            value = patternValue(pattern, t, showTime);
        }
        // Overlay-style mix: keeps blacks black instead of washing the layer out.
        rgb = mix(rgb, rgb * value, texAmount);
    }

    float alpha = color.a * opacity;

    // Feathered edges for soft edge-blending between overlapping projections.
    if (feather > 0.0) {
        float2 d = min(in.uv, 1.0 - in.uv);
        float edge = min(smoothstep(0.0, feather, d.x), smoothstep(0.0, feather, d.y));
        alpha *= edge;
    }

    rgb *= intensity;

    // Per-blend-mode source preparation; the matching blend factors are set on
    // the pipeline state.
    switch (blendIndex) {
        case 2: // screen: one, oneMinusSourceColor
            return float4(saturate(rgb) * alpha, alpha);
        case 3: // multiply: destinationColor, zero
            return float4(mix(float3(1.0), rgb, alpha), alpha);
        default: // normal and add rely on the source alpha factor
            return float4(rgb, alpha);
    }
}
