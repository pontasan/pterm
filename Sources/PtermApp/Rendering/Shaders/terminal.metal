#include <metal_stdlib>
using namespace metal;

/// Vertex data for a single glyph quad.
struct VertexIn {
    float2 position  [[attribute(0)]]; // Screen-space position
    float2 texCoord  [[attribute(1)]]; // Texture coordinate in glyph atlas
    float4 fgColor   [[attribute(2)]]; // Foreground color (RGBA)
    float4 bgColor   [[attribute(3)]]; // Background color (RGBA)
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 fgColor;
    float4 bgColor;
};

/// Uniforms passed per frame.
struct Uniforms {
    float2 viewportSize;
    float  cursorOpacity; // For smooth cursor fade animation
    float  cursorBlink;   // 1.0 = blinking, 0.0 = steady
    float  time;
};

// MARK: - Background Vertex/Fragment

/// Vertex shader for cell backgrounds.
vertex VertexOut bg_vertex(
    uint vertexID [[vertex_id]],
    constant VertexIn *vertices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;
    VertexIn in = vertices[vertexID];

    // Convert pixel coordinates to Metal NDC (-1..1)
    float2 ndc = (in.position / uniforms.viewportSize) * 2.0 - 1.0;
    ndc.y = -ndc.y; // Flip Y (Metal has origin at bottom-left)

    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.fgColor = in.fgColor;
    out.bgColor = in.bgColor;
    return out;
}

/// Fragment shader for cell backgrounds.
fragment float4 bg_fragment(VertexOut in [[stage_in]]) {
    return in.bgColor;
}

// MARK: - Glyph Vertex/Fragment

/// Vertex shader for glyph rendering.
vertex VertexOut glyph_vertex(
    uint vertexID [[vertex_id]],
    constant VertexIn *vertices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    VertexOut out;
    VertexIn in = vertices[vertexID];

    float2 ndc = (in.position / uniforms.viewportSize) * 2.0 - 1.0;
    ndc.y = -ndc.y;

    out.position = float4(ndc, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.fgColor = in.fgColor;
    out.bgColor = in.bgColor;
    return out;
}

/// Fragment shader for glyph rendering.
/// Samples from the glyph atlas texture and applies foreground color.
fragment float4 glyph_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float4 texColor = atlas.sample(atlasSampler, in.texCoord);
    // The atlas stores grayscale glyphs: use alpha channel for coverage
    float coverage = texColor.r; // Monochrome glyph
    return float4(in.fgColor.rgb, coverage * in.fgColor.a);
}

/// Low-DPI glyph fragment.
/// External 1x displays benefit from slightly stronger coverage so stems don't
/// wash out after bilinear downsampling from the oversampled atlas.
fragment float4 lowdpi_glyph_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]],
    sampler atlasSampler [[sampler(0)]]
) {
    float4 texColor = atlas.sample(atlasSampler, in.texCoord);
    float coverage = pow(clamp(texColor.r, 0.0, 1.0), 0.88);
    return float4(in.fgColor.rgb, coverage * in.fgColor.a);
}

/// Fragment shader for compositing pre-rendered RGBA thumbnail surfaces.
fragment float4 texture_fragment(
    VertexOut in [[stage_in]],
    texture2d<float> sourceTexture [[texture(0)]],
    sampler sourceSampler [[sampler(0)]]
) {
    float4 sampleColor = sourceTexture.sample(sourceSampler, in.texCoord);
    if (sampleColor.a <= 0.0001) {
        return float4(0.0);
    }
    return float4(sampleColor.rgb / sampleColor.a, sampleColor.a);
}

// MARK: - Cursor

/// Fragment shader for cursor with optional smooth blink.
fragment float4 cursor_fragment(
    VertexOut in [[stage_in]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    float alpha;
    if (uniforms.cursorBlink > 0.5) {
        // Keep blink subtle to avoid whole-cell flicker on idle terminals.
        alpha = 0.5 + 0.5 * sin(uniforms.time * 2.0);
        alpha = 0.78 + alpha * 0.22;
    } else {
        alpha = 1.0;
    }
    return float4(in.fgColor.rgb, alpha * uniforms.cursorOpacity);
}

// MARK: - Overlay

/// Fragment shader for UI overlays (scrollbar, etc.).
/// Simple pass-through of foreground color with alpha blending.
fragment float4 overlay_fragment(VertexOut in [[stage_in]]) {
    return in.fgColor;
}

/// Fragment shader for anti-aliased circles rendered analytically from quad UVs.
/// This avoids texture aliasing on external displays and across backing-scale changes.
fragment float4 circle_fragment(VertexOut in [[stage_in]]) {
    float2 centered = in.texCoord * 2.0 - 1.0;
    float dist = length(centered);
    float aa = max(fwidth(dist), 0.001);
    constexpr float radius = 0.92;
    float coverage = 1.0 - smoothstep(radius - aa, radius + aa, dist);
    return float4(in.fgColor.rgb, in.fgColor.a * coverage);
}
