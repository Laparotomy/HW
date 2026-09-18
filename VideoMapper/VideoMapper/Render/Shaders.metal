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
    float4 params4;        // generatorIndex, genSpeed, genScale, genComplexity
    float4 params5;        // paletteIndex, genDrive, genVariation, unused
    float4 params6;        // uvOriginX, uvOriginY, uvSizeX, uvSizeY (mesh cell slice)
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
    // The homography maps this *cell's* unit square onto the canvas, so the texture
    // coordinate has to be lifted back into the whole layer's space. With one cell
    // the slice is (0, 0, 1, 1) and this is the identity.
    out.uv = u.params6.xy + uv * u.params6.zw;
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

// MARK: - Generator library
//
// Abstract sources synthesised here rather than played back from video files.
// Every one is a pure function of (uv, showTime), which is what lets a phone and a
// projector — or two phones in an ensemble — draw a bit-identical frame from the
// same show clock with no seeking, no drift correction and no media to distribute.

static float hash11(float n) {
    return fract(sin(n * 127.1) * 43758.5453);
}

static float2 hash22(float2 p) {
    float2 q = float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)));
    return fract(sin(q) * 43758.5453);
}

// Fractal value noise. Octaves fade in with `complexity` rather than switching on,
// so dragging the slider never pops.
static float fbm(float2 p, float complexity) {
    float sum = 0.0;
    float amp = 0.5;
    float norm = 0.0;
    for (int i = 0; i < 5; i++) {
        float w = saturate(complexity * 5.0 - float(i) + 1.0);
        if (w <= 0.0) { break; }
        sum += valueNoise(p) * amp * w;
        norm += amp * w;
        p *= 2.02;
        amp *= 0.5;
    }
    return norm > 0.0 ? sum / norm : 0.0;
}

// Distance to the nearest of a drifting point set; the basis of the cell pattern.
static float voronoi(float2 p, float time) {
    float2 cell = floor(p);
    float2 f = fract(p);
    float best = 8.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 g = float2(i, j);
            float2 o = hash22(cell + g);
            o = 0.5 + 0.5 * sin(time + 6.2831853 * o);
            float2 r = g + o - f;
            best = min(best, dot(r, r));
        }
    }
    return sqrt(best);
}

// Cosine gradient ramps: a + b * cos(2pi * (t + d)), one phase offset per channel.
// A few instructions, smooth at any projector resolution, and no texture to bind.
static float3 palette(float t, int index) {
    t = fract(t);
    if (index == 0) { return float3(saturate(t)); }

    float3 a, b, d;
    switch (index) {
        case 1:  a = float3(0.50, 0.25, 0.10); b = float3(0.50, 0.30, 0.15); d = float3(0.00, 0.15, 0.30); break; // ember
        case 2:  a = float3(0.20, 0.40, 0.60); b = float3(0.30, 0.35, 0.40); d = float3(0.60, 0.50, 0.40); break; // ice
        case 3:  a = float3(0.60, 0.30, 0.60); b = float3(0.40, 0.30, 0.40); d = float3(0.00, 0.25, 0.50); break; // neon
        case 4:  a = float3(0.50, 0.50, 0.50); b = float3(0.50, 0.50, 0.50); d = float3(0.00, 0.33, 0.67); break; // rainbow
        case 5:  a = float3(0.60, 0.35, 0.40); b = float3(0.40, 0.30, 0.30); d = float3(0.00, 0.10, 0.20); break; // sunset
        case 6:  a = float3(0.40, 0.60, 0.30); b = float3(0.30, 0.40, 0.30); d = float3(0.10, 0.00, 0.30); break; // toxic
        case 8:  a = float3(0.50, 0.13, 0.08); b = float3(0.50, 0.28, 0.12); d = float3(0.00, 0.08, 0.18); break; // magma
        case 9:  a = float3(0.08, 0.28, 0.42); b = float3(0.14, 0.30, 0.42); d = float3(0.55, 0.62, 0.72); break; // ocean
        case 10: a = float3(0.65, 0.48, 0.62); b = float3(0.35, 0.40, 0.35); d = float3(0.80, 0.92, 0.28); break; // candy
        case 11: a = float3(0.34, 0.26, 0.46); b = float3(0.34, 0.24, 0.36); d = float3(0.68, 0.86, 0.14); break; // dusk
        default: a = float3(0.55, 0.60, 0.68); b = float3(0.20, 0.20, 0.22); d = float3(0.10, 0.15, 0.20); break; // mist
    }
    return saturate(a + b * cos(6.2831853 * (t + d)));
}

static float3 generatePlasma(float2 p, float time, float scale, float drive, int pal) {
    float2 q = p * scale;
    float v = sin(q.x + time)
            + sin(q.y + time * 1.3)
            + sin((q.x + q.y) * 0.7 + time * 0.7)
            + sin(length(q) * 1.2 - time * 1.7);
    v = v * 0.125 + 0.5;
    return palette(v + drive * 0.25, pal);
}

static float3 generateClouds(float2 p, float time, float scale, float complexity,
                             float drive, float seed, int pal) {
    float2 q = p * scale + float2(time * 0.15, -time * 0.1) + seed;
    // Domain warp: sampling noise at a noise-displaced position is what turns flat
    // static into something that reads as smoke.
    float2 warp = float2(fbm(q + 1.7, complexity), fbm(q - 4.3, complexity)) - 0.5;
    float v = fbm(q + warp * (1.0 + complexity * 2.0), complexity);
    v = smoothstep(0.25, 0.85, v + drive * 0.2);
    return palette(v * 0.6 + 0.1, pal) * v;
}

static float3 generateTunnel(float2 p, float time, float scale, float drive, int pal) {
    float r = max(length(p), 0.001);
    float a = atan2(p.y, p.x) / 6.2831853;
    float depth = 0.25 / r + time * 0.6;
    float bands = 0.5 + 0.5 * sin(depth * scale + sin(a * 12.566371) * 0.6);
    // Fade the singularity at the centre, or it aliases into a bright dot.
    float vignette = smoothstep(0.0, 0.25, r);
    float v = bands * vignette * (1.0 + drive * 0.6);
    return palette(depth * 0.05 + v * 0.3, pal) * saturate(v);
}

static float3 generateKaleidoscope(float2 p, float time, float scale, float complexity,
                                   float drive, float seed, int pal) {
    float segments = 6.0 + floor(complexity * 6.0) * 2.0;
    float r = length(p);
    float a = atan2(p.y, p.x) / 6.2831853;
    // Fold the angle into one mirrored wedge.
    a = abs(fract(a * segments) - 0.5) * 2.0;
    float2 q = float2(cos(a * 3.14159265), sin(a * 3.14159265)) * r * scale;
    float v = fbm(q + seed + time * 0.3, complexity);
    v = saturate(v + drive * 0.25);
    return palette(v + r * 0.3, pal);
}

static float3 generateCells(float2 p, float time, float scale, float drive,
                            float seed, int pal) {
    float d = voronoi(p * scale + seed, time);
    // Bright seams, dark interiors: the edges are what read on a textured surface.
    float edge = smoothstep(0.45, 0.0, d);
    float body = smoothstep(0.0, 0.9, d);
    float v = saturate(body * 0.5 + edge * (0.6 + drive * 0.6));
    return palette(body * 0.4 + 0.15, pal) * v;
}

static float3 generateRings(float2 p, float time, float scale, float drive, int pal) {
    float r = length(p);
    float v = 0.5 + 0.5 * sin(r * scale * 6.2831853 - time * 6.0);
    // saturate() before pow(): rounding can leave v a hair below zero, and a
    // negative base would come back NaN.
    v = pow(saturate(v), 2.0 + (1.0 - drive) * 4.0);
    v *= smoothstep(0.85, 0.0, r);
    return palette(r * 0.8 + time * 0.05, pal) * saturate(v * (1.0 + drive));
}

static float3 generateWaves(float2 p, float time, float scale, float drive, int pal) {
    float v = 0.0;
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float angle = fi * 2.094395 + time * 0.13;
        float2 dir = float2(cos(angle), sin(angle));
        v += sin(dot(p, dir) * scale * (1.0 + fi * 0.35) + time * (1.0 + fi * 0.4));
    }
    v = v / 3.0 * 0.5 + 0.5;
    return palette(v + drive * 0.2, pal);
}

static float3 generateGrid(float2 p, float time, float scale, float drive, int pal) {
    // uv runs y-down, so the floor plane is the lower half.
    float3 sky = palette(0.15 + p.y * 0.3, pal) * smoothstep(-0.5, 0.05, p.y) * 0.35;
    if (p.y <= 0.004) { return sky; }

    float z = 0.25 / p.y;
    float x = p.x * z;
    float gx = abs(fract(x * scale * 0.25) - 0.5);
    float gz = abs(fract((z + time) * scale * 0.25) - 0.5);
    // Line width grows with distance so far lines do not alias into noise.
    float w = 0.03 + 0.05 * saturate(z * 0.05);
    float line = smoothstep(w, 0.0, gx) + smoothstep(w, 0.0, gz);
    float fade = smoothstep(40.0, 2.0, z);
    float v = saturate(line * fade * (1.0 + drive));
    return palette(0.55 + p.y * 0.4, pal) * v;
}

static float3 generateStarfield(float2 p, float time, float scale, float drive,
                                float seed, int pal) {
    float spokes = max(scale, 1.0) * 20.0;
    float r = length(p);
    float a = atan2(p.y, p.x) / 6.2831853 + 0.5;
    float cell = floor(a * spokes) + seed;
    float3 acc = float3(0.0);
    // Three interleaved depth layers give parallax without three passes.
    for (int i = 0; i < 3; i++) {
        float id = cell + float(i) * 131.0;
        float z = fract(hash11(id) + time * (0.25 + float(i) * 0.12));
        float radius = z * z * 0.9;
        // Arc length from the cell's centre line: the cell subtends 2*pi*r/spokes.
        float arc = (fract(a * spokes) - 0.5) * 6.2831853 * r / spokes;
        float d = length(float2(arc, r - radius));
        float star = smoothstep(0.012 + 0.02 * z, 0.0, d) * z;
        acc += palette(hash11(id + 7.0), pal) * star;
    }
    return acc * (1.0 + drive * 1.5);
}

static float3 generateAurora(float2 p, float time, float scale, float complexity,
                             float drive, float seed, int pal) {
    float3 acc = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        float offset = seed + fi * 17.0;
        float ridge = fbm(float2(p.x * scale + offset, time * 0.25 + fi), complexity);
        float centre = -0.1 + fi * 0.12 + (ridge - 0.5) * 0.7;
        float width = 0.08 + 0.05 * fi + drive * 0.05;
        // Squared by multiplication, not pow(): the base here is signed, and
        // pow() with a negative base is undefined in MSL (it goes through log2).
        float offsetFromBand = (p.y - centre) / width;
        float band = exp(-offsetFromBand * offsetFromBand);
        acc += palette(0.3 + fi * 0.15 + ridge * 0.2, pal) * band;
    }
    return acc * (0.8 + drive * 0.8);
}

static float3 generateMetaballs(float2 p, float time, float scale, float drive, int pal) {
    float field = 0.0;
    for (int i = 0; i < 5; i++) {
        float fi = float(i);
        float2 c = 0.33 * float2(sin(time * (0.7 + fi * 0.13) + fi * 1.7),
                                 cos(time * (0.5 + fi * 0.17) + fi * 2.3));
        field += 0.02 * (1.0 + drive * 0.8) / max(dot(p - c, p - c), 0.0005);
    }
    field *= max(scale, 0.5) * 0.3;
    float v = smoothstep(0.6, 1.4, field);
    return palette(field * 0.15, pal) * v;
}

static float3 generateStrobe(float time, float drive, int pal) {
    // Sawtooth decay rather than a square wave: a hard on/off flash at 60 fps reads
    // as a flicker, a fast decay reads as a hit.
    float pulse = pow(1.0 - fract(time), 6.0);
    float v = saturate(max(pulse, drive));
    return palette(0.5 + v * 0.5, pal) * v;
}

// A logarithmic spiral: the arm count stays constant at every radius, which is what
// keeps it readable when it is warped onto something round.
static float3 generateSpiral(float2 p, float time, float scale, float complexity,
                             float drive, int pal) {
    float r = length(p);
    float a = atan2(p.y, p.x);
    float arms = 2.0 + floor(complexity * 6.0);
    float v = 0.5 + 0.5 * sin(a * arms + log(max(r, 0.02)) * scale - time * 2.0);
    v = pow(saturate(v), 2.0);
    v *= smoothstep(0.95, 0.05, r);
    return palette(0.4 + r * 0.5 + time * 0.03, pal) * saturate(v * (1.0 + drive));
}

// Two line sets at slowly diverging angles. The beat pattern between them is the
// whole effect, and it is far stronger than either set alone — which is also why the
// second set is detuned by 4%: identical spacings would just give one set back.
static float3 generateMoire(float2 p, float time, float scale, float drive, int pal) {
    float a1 = time * 0.11;
    float a2 = -time * 0.13 + 0.15;
    float2 d1 = float2(cos(a1), sin(a1));
    float2 d2 = float2(cos(a2), sin(a2));
    float s = scale * 6.0 * (1.0 + drive * 0.3);
    float l1 = 0.5 + 0.5 * cos(dot(p, d1) * s);
    float l2 = 0.5 + 0.5 * cos(dot(p, d2) * s * 1.04);
    float v = saturate(l1 * l2 * 2.0);
    return palette(v * 0.5 + time * 0.04, pal) * v;
}

static float3 generateLightning(float2 p, float time, float scale, float complexity,
                                float drive, float seed, int pal) {
    float3 acc = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float fi = float(i);
        // A strike lives for one slot and a new one is seeded after it, so the
        // pattern never repeats and nothing has to be stored between frames.
        float slot = floor(time * 0.5 + fi * 0.37);
        float life = fract(time * 0.5 + fi * 0.37);
        float x = hash11(slot + seed + fi * 53.0) * 2.0 - 1.0;
        float wander = (fbm(float2(p.y * scale * 0.5, slot + seed), complexity) - 0.5) * 0.9;
        float d = abs(p.x - x * 0.6 - wander);
        float core = smoothstep(0.02, 0.0, d);
        float glow = smoothstep(0.16, 0.0, d) * 0.35;
        float flash = pow(saturate(1.0 - life), 5.0);
        acc += palette(0.62 + fi * 0.06, pal) * (core + glow) * flash;
    }
    return acc * (0.7 + drive * 2.0);
}

static float3 generateFireflies(float2 p, float time, float scale, float drive,
                                float seed, int pal) {
    float cells = max(scale, 1.0) * 1.5;
    float2 q = p * cells;
    float2 base = floor(q);
    float3 acc = float3(0.0);
    // Only the nine cells around the sample can hold a fly close enough to see.
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float2 cell = base + float2(i, j);
            float2 rnd = hash22(cell + seed);
            float id = rnd.x + rnd.y * 37.0;
            float2 centre = cell + 0.5 + 0.35 * float2(sin(time * (0.4 + rnd.x) + rnd.y * 6.2831853),
                                                       cos(time * (0.3 + rnd.y) + rnd.x * 6.2831853));
            float pulse = 0.35 + 0.65 * (0.5 + 0.5 * sin(time * (1.1 + rnd.x * 1.7) + id * 6.2831853));
            float d = length(q - centre) / max(cells, 0.001);
            float glow = smoothstep(0.03, 0.0, d) + smoothstep(0.09, 0.0, d) * 0.25;
            acc += palette(0.1 + rnd.x * 0.3, pal) * glow * pulse;
        }
    }
    return acc * (1.0 + drive * 1.2);
}

static float3 generateHexes(float2 p, float time, float scale, float drive,
                            float seed, int pal) {
    // A hex lattice is two rectangular lattices offset by half a cell; whichever
    // centre is nearer is the one this pixel belongs to.
    const float2 s = float2(1.0, 1.7320508);
    float2 q = p * max(scale, 0.5);
    float2 hc = floor(q / s) + 0.5;
    float2 a = q - hc * s;
    float2 b = q - (hc + 0.5) * s;
    float2 g = dot(a, a) < dot(b, b) ? a : b;
    float2 centre = q - g;
    float id = centre.x * 7.3 + centre.y * 13.7 + seed;

    // Distance in the six-fold metric: the Voronoi cell's flat sides sit at 0.5.
    float hex = max(abs(g.x), dot(abs(g), float2(0.5, 0.8660254)));
    float body = smoothstep(0.50, 0.46, hex);
    float inner = smoothstep(0.46, 0.42, hex);
    float rim = saturate(body - inner);
    float lit = 0.5 + 0.5 * sin(time * 2.0 + hash11(id) * 6.2831853);
    float v = saturate(inner * (0.1 + lit * 0.85) + rim * 0.9);
    return palette(hash11(id + 3.0) * 0.4 + 0.2, pal) * v * (1.0 + drive * 0.8);
}

static float3 generateLiquid(float2 p, float time, float scale, float complexity,
                             float drive, float seed, int pal) {
    // A height field sampled three times a short step apart. The slope stands in for
    // a surface normal, and the places where it flattens out are the caustics — far
    // cheaper than tracing anything, and it reads as water from across a room.
    float2 drift = float2(time * 0.2, time * 0.13);
    float2 q = p * scale + seed + drift;
    float h = fbm(q, complexity);
    float hx = fbm(q + float2(0.06, 0.0), complexity);
    float hy = fbm(q + float2(0.0, 0.06), complexity);
    float2 slope = float2(hx - h, hy - h) * 40.0;
    float flatness = saturate(1.0 - length(slope) * 0.35);
    float caustic = pow(flatness, 3.0);
    float v = saturate(h * 0.55 + caustic * (0.8 + drive * 0.8));
    return palette(h * 0.5 + 0.1 + length(slope) * 0.1, pal) * v;
}

static float3 generateSweep(float2 p, float time, float scale, float complexity,
                            float drive, int pal) {
    // Complexity is the bar's angle, not its detail: one source then covers a bar
    // crossing a wide wall and a bar running down a column.
    float angle = complexity * 3.14159265;
    float2 dir = float2(cos(angle), sin(angle));
    float travel = dot(p, dir) * 0.7 + 0.5;
    float head = fract(time * 0.5);
    float d = travel - head;
    // Wrap to the nearest cycle, so the bar re-enters instead of jumping.
    d -= floor(d + 0.5);
    float width = 0.02 + 0.2 / max(scale, 0.5);
    float bar = smoothstep(width, 0.0, abs(d));
    float trail = smoothstep(width * 6.0, 0.0, max(-d, 0.0)) * 0.35;
    float v = saturate((bar + trail) * (1.0 + drive));
    return palette(0.55 + d, pal) * v;
}

static float3 generateBars(float2 uv, float time, float scale, float drive,
                           float seed, int pal) {
    // A level meter, and the only source here whose point is the audio: with nothing
    // driving it the bars still breathe, but they only really move when fed.
    float count = clamp(floor(scale * 2.0), 3.0, 32.0);
    float slot = floor(uv.x * count);
    float within = fract(uv.x * count);
    float body = smoothstep(0.08, 0.16, within) * smoothstep(0.92, 0.84, within);
    float id = slot + seed;
    float sway = 0.5 + 0.5 * sin(time * (1.3 + hash11(id) * 2.0) + hash11(id + 9.0) * 6.2831853);
    float height = saturate(0.15 + sway * 0.3 + drive * 0.7);
    // uv runs y-down, so a bar of this height grows up from the bottom edge.
    float top = 1.0 - height;
    float fill = smoothstep(top + 0.012, top - 0.012, uv.y);
    return palette(0.12 + height * 0.55, pal) * saturate(body * fill);
}

static float3 generateConfetti(float2 uv, float time, float scale, float drive,
                               float seed, int pal) {
    float columns = clamp(floor(scale * 6.0), 6.0, 90.0);
    float x = uv.x * columns;
    float col = floor(x);
    float within = fract(x) - 0.5;
    float3 acc = float3(0.0);
    // Two flakes per column, each on its own fall rate, which is enough to stop the
    // field reading as rows.
    for (int i = 0; i < 2; i++) {
        float id = col + float(i) * 311.0 + seed;
        float speed = 0.25 + hash11(id) * 0.5;
        float y = fract(uv.y - time * speed - hash11(id + 5.0));
        float2 d = float2(within * 1.6, (y - 0.5) * 6.0);
        float piece = smoothstep(0.5, 0.0, length(d));
        acc += palette(hash11(id + 11.0), pal) * piece;
    }
    return acc * (0.9 + drive * 1.1);
}

static float3 generateRipple(float2 p, float time, float scale, float drive,
                             float seed, int pal) {
    float3 acc = float3(0.0);
    // Four drops, staggered so one is always mid-spread and the surface is never
    // entirely still.
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        float slot = floor(time * 0.4 + fi * 0.25);
        float life = fract(time * 0.4 + fi * 0.25);
        float2 c = (hash22(float2(slot, fi) + seed) - 0.5) * 0.9;
        float front = life * 0.8;
        float d = abs(length(p - c) - front);
        float w = 0.01 + life * 0.04 + 0.6 / max(scale * 8.0, 1.0);
        float ring = smoothstep(w, 0.0, d);
        // Fading as it spreads is what stops the oldest ring sitting on the frame edge.
        acc += palette(0.45 + fi * 0.1 + front, pal) * ring * (1.0 - life);
    }
    return acc * (1.0 + drive * 1.2);
}

static float3 generateMatrix(float2 uv, float time, float scale, float drive,
                             float seed, int pal) {
    float columns = clamp(floor(scale * 5.0), 6.0, 80.0);
    float x = uv.x * columns;
    float col = floor(x);
    float gutter = smoothstep(0.42, 0.3, abs(fract(x) - 0.5));

    float id = col + seed;
    float speed = 0.2 + hash11(id) * 0.5;
    float head = fract(time * speed + hash11(id + 3.0));
    // Distance behind the head, wrapped, so a trail that runs off the bottom comes
    // back in at the top without a seam.
    float d = head - uv.y;
    d -= floor(d);
    float trail = pow(saturate(1.0 - d * (3.0 + hash11(id + 7.0) * 5.0)), 2.0);
    // Cells flickering within the column is what sells this as falling glyphs
    // rather than a gradient.
    float cell = floor(uv.y * columns * 1.2);
    float flicker = 0.55 + 0.45 * hash11(cell * 3.7 + id + floor(time * 8.0));
    float3 colour = palette(0.3 + trail * 0.25, pal);
    // The leading character is near-white, which is what gives the trail direction.
    colour = mix(colour, float3(1.0), smoothstep(0.9, 1.0, trail));
    return colour * saturate(gutter * trail * flicker) * (0.9 + drive);
}

static float3 generateNebula(float2 p, float time, float scale, float complexity,
                             float drive, float seed, int pal) {
    float2 q = p * scale + seed;
    float2 drift = float2(time * 0.06, -time * 0.04);
    // One warp field shared by both shells. A second would double the noise cost
    // for a difference nobody sees on a wall.
    float2 w = float2(fbm(q + drift + 2.3, complexity),
                      fbm(q - drift - 5.1, complexity)) - 0.5;
    float3 acc = float3(0.0);
    for (int i = 0; i < 2; i++) {
        float fi = float(i);
        float2 s = q * (1.0 + fi * 0.55) + w * (1.8 + fi * 0.9) + drift * (1.0 + fi);
        float density = smoothstep(0.34 + fi * 0.08, 0.92, fbm(s, complexity));
        acc += palette(0.12 + fi * 0.3 + density * 0.2, pal) * density * (0.75 - fi * 0.2);
    }
    // A bright core, so the thing has somewhere to look.
    float core = exp(-dot(p, p) * 5.0);
    acc += palette(0.06, pal) * core * (0.35 + drive * 0.5);
    return acc * (1.0 + drive * 0.5);
}

// Dispatches to the selected generator. Index 0 means the layer is media-backed and
// this is never called.
static float3 generate(int index, float2 uv, float aspect, float showTime,
                       float speed, float scale, float complexity,
                       float drive, float variation, int pal) {
    float2 p = uv - 0.5;
    p.x *= aspect;
    float time = showTime * speed;
    float seed = variation * 37.0;

    switch (index) {
        case 1:  return generatePlasma(p, time, scale, drive, pal);
        case 2:  return generateClouds(p, time, scale, complexity, drive, seed, pal);
        case 3:  return generateTunnel(p, time, scale, drive, pal);
        case 4:  return generateKaleidoscope(p, time, scale, complexity, drive, seed, pal);
        case 5:  return generateCells(p, time, scale, drive, seed, pal);
        case 6:  return generateRings(p, time, scale, drive, pal);
        case 7:  return generateWaves(p, time, scale, drive, pal);
        case 8:  return generateGrid(p, time, scale, drive, pal);
        case 9:  return generateStarfield(p, time, scale, drive, seed, pal);
        case 10: return generateAurora(p, time, scale, complexity, drive, seed, pal);
        case 11: return generateMetaballs(p, time, scale, drive, pal);
        case 12: return generateStrobe(time, drive, pal);
        case 13: return generateSpiral(p, time, scale, complexity, drive, pal);
        case 14: return generateMoire(p, time, scale, drive, pal);
        case 15: return generateLightning(p, time, scale, complexity, drive, seed, pal);
        case 16: return generateFireflies(p, time, scale, drive, seed, pal);
        case 17: return generateHexes(p, time, scale, drive, seed, pal);
        case 18: return generateLiquid(p, time, scale, complexity, drive, seed, pal);
        case 19: return generateSweep(p, time, scale, complexity, drive, pal);
        // These four are laid out against the frame rather than around its centre,
        // so they take the raw uv: a meter has to start at the bottom edge and a
        // column of rain has to run the full height however wide the canvas is.
        case 20: return generateBars(uv, time, scale, drive, seed, pal);
        case 21: return generateConfetti(uv, time, scale, drive, seed, pal);
        case 22: return generateRipple(p, time, scale, drive, seed, pal);
        case 23: return generateMatrix(uv, time, scale, drive, seed, pal);
        case 24: return generateNebula(p, time, scale, complexity, drive, seed, pal);
        default: return float3(0.0);
    }
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
    int   generator   = int(u.params4.x + 0.5);

    float3 rgb = color.rgb;

    // A generator replaces the sampled media entirely; everything downstream
    // (saturation, tint, texture overlay, feather, blend) applies to it unchanged,
    // so a generated layer is adjustable exactly like a clip.
    if (generator > 0) {
        rgb = generate(generator, in.uv, aspect, showTime,
                       u.params4.y, max(u.params4.z, 0.0001), saturate(u.params4.w),
                       saturate(u.params5.y), u.params5.z, int(u.params5.x + 0.5));
    }

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
