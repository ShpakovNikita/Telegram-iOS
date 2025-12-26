#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position;
    float2 uv;
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct Uniforms {
    float2 size;
    float cornerRadius;
    float padding; // Alignment padding
    float4 glassRect; // normalized x, y, w, h in texture space
};

float sdRoundedBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

vertex VertexOut magnifying_glass_vertex(uint vertexID [[vertex_id]],
                                      constant VertexIn *vertices [[buffer(1)]],
                                      constant Uniforms &uniforms [[buffer(0)]]) {
    VertexOut out;
    
    out.position = vertices[vertexID].position;
    out.uv = vertices[vertexID].uv;
    return out;
}

fragment float4 magnifying_glass_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> backgroundTexture [[texture(0)]],
                                       texture2d<float> iconTexture [[texture(1)]],
                                       constant Uniforms &uniforms [[buffer(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = in.uv;
    float2 size = uniforms.size;
    float2 p = (uv - 0.5) * size;
    float2 b = size * 0.5;
    float d = sdRoundedBox(p, b, uniforms.cornerRadius);
    
    // Mask
    float alpha = 1.0 - smoothstep(-1.0, 0.0, d);
    if (alpha <= 0.001) discard_fragment();
    
    // Lens Distortion (Flat)
    // Magnification 1.0 ensures content stays perfectly in place (no parallax)
    float magnification = 1.12;
    float2 lensUV = 0.5 + (uv - 0.5) / magnification;
    
    // Background Sampling
    float2 bgUVStart = uniforms.glassRect.xy; // glassRect.xy is start UV (normalized)
    
    // uniforms.glassRect.zw is width/height in UV space (normalized)
    float2 bgUVSize = uniforms.glassRect.zw;
    float2 bgUV = bgUVStart + lensUV * bgUVSize;
    
    float4 bg = backgroundTexture.sample(textureSampler, bgUV);
    
    // Icon Sampling
    // Icons texture matches background size/coords.
    // So we use same UVs.
    float4 icon = iconTexture.sample(textureSampler, bgUV);
    
    // Composite
    // Icons on top of background
    float4 content = mix(bg, icon, icon.a);
    
    // Apply Mask
    return float4(content.rgb, 1.0);
}
