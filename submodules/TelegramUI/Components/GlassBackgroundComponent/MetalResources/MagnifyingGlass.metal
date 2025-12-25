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
    float2 padding;
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
                                       constant Uniforms &uniforms [[buffer(0)]]) {
    float2 uv = in.uv;
    float2 size = uniforms.size;
    float2 p = (uv - 0.5) * size;
    float2 b = size * 0.5;
    float d = sdRoundedBox(p, b, uniforms.cornerRadius);
    
    // Anti-aliasing
    float alpha = 1.0 - smoothstep(-1.0, 0.0, d);
    
    return float4(0.0, 0.0, 0.0, alpha);
}
