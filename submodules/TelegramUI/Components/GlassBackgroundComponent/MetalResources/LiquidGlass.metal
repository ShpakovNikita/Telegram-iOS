#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float4 position;
    float2 texCoord;
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct Uniforms {
    float2 size;
    float4 tintColor;
    float cornerRadius;
    float padding;
    float4 screenRect;
};

vertex VertexOut liquid_glass_vertex(uint vertexID [[vertex_id]],
                                     constant VertexIn *vertices [[buffer(0)]],
                                     constant Uniforms &uniforms [[buffer(1)]]) {
    VertexOut out;
    out.position = vertices[vertexID].position;
    out.texCoord = vertices[vertexID].texCoord;
    return out;
}

float roundedRectSDF(float2 p, float2 size, float radius) {
    float2 d = abs(p) - size + radius;
    return min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - radius;
}

fragment float4 liquid_glass_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> texture [[texture(0)]],
                                      constant Uniforms &uniforms [[buffer(1)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    
    float2 uv = in.texCoord;
    float2 p = uv - 0.5;
    
    float2 size = uniforms.size;
    float2 pixelPos = p * size;
    float2 halfSize = size * 0.5;
    
    float dist = roundedRectSDF(pixelPos, halfSize, uniforms.cornerRadius);
    if (dist > 0) {
        discard_fragment();
        return float4(0.0);
    }
    
    float rimSize = 20.0;
    float displacement = smoothstep(rimSize, 0.0, abs(dist));
    
    float scaleFactor = 1.0 + displacement * 0.1;
    
    float2 distortedLocalUV = (p / scaleFactor) + 0.5;
    
    float2 screenUV = uniforms.screenRect.xy + (distortedLocalUV * uniforms.screenRect.zw);
    
    float4 texColor = texture.sample(textureSampler, screenUV);
    
    float4 color = uniforms.tintColor;
    float alpha = smoothstep(-1.0, 0.0, dist); 
    
    float4 combined = mix(texColor, color, color.a * (0.5 + displacement * 0.5));
    
    return combined;
}
