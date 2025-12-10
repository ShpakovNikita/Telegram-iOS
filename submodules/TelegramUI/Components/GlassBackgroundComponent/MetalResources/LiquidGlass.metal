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
    float time;
    float2 size;
    float4 tintColor;
    float cornerRadius;
    float padding;
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
                                      texture2d<float> backgroundTexture [[texture(0)]],
                                      constant Uniforms &uniforms [[buffer(1)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    
    float2 uv = in.texCoord;
    float2 p = uv - 0.5;
    
    float2 size = uniforms.size;
    float2 pixelPos = p * size;
    float2 halfSize = size * 0.5;
    
    float dist = roundedRectSDF(pixelPos, halfSize, uniforms.cornerRadius);
    if (dist > 0) {
        return float4(0.0);
    }
    
    float rimSize = 20.0; // Adjustable rim size
    float displacement = smoothstep(rimSize, 0.0, abs(dist)); 
    
    float scaleFactor = 1.0 + displacement * 0.1; // Slight bulge at the edge
    
    float2 distortedUV = (p / scaleFactor) + 0.5;
    
    float4 color = uniforms.tintColor;
    
    float alpha = smoothstep(-1.0, 0.0, dist); // Soft edge?
    
    float4 texColor = backgroundTexture.sample(textureSampler, distortedUV);
    // color = mix(color, texColor, 0.5);
    
    return texColor;//return color;
}
