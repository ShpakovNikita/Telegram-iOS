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

float sdfRect(float2 center, float2 size, float2 p, float r) {
    float2 p_rel = p - center;
    float2 q = abs(p_rel) - size;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float3 getNormal(float sd, float thickness) {
    float dx = dfdx(sd);
    float dy = dfdy(sd);

    float n_cos = max(thickness + sd, 0.0) / thickness;
    float n_sin = sqrt(1.0 - n_cos * n_cos);

    return normalize(float3(dx * n_cos, dy * n_cos, n_sin));
}

float height(float sd, float thickness) {
    if (sd >= 0.0) {
        return 0.0;
    }
    if (sd < -thickness) {
        return thickness;
    }

    float x = thickness + sd;
    return sqrt(thickness * thickness - x * x);
}

float4 gaussian_blur(texture2d<float> texture, sampler textureSampler, float2 uv, float radius) {
    if (radius <= 0.0) {
        return texture.sample(textureSampler, uv);
    }
    
    float2 texelSize = float2(1.0 / texture.get_width(), 1.0 / texture.get_height());
    float4 color = float4(0.0);
    float totalWeight = 0.0;

    int steps = int(radius);
    if (steps > 10) steps = 10;
    
    float sigma = float(steps) / 2.0;
    if (sigma < 1.0) sigma = 1.0;
    
    for (int x = -steps; x <= steps; x++) {
        for (int y = -steps; y <= steps; y++) {
            float2 offset = float2(float(x), float(y)) * texelSize;
            float weight = exp(-(float(x*x + y*y)) / (2.0 * sigma * sigma));
            
            color += texture.sample(textureSampler, uv + offset) * weight;
            totalWeight += weight;
        }
    }
    
    return color / totalWeight;
}

fragment float4 liquid_glass_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> texture [[texture(0)]],
                                      constant Uniforms &uniforms [[buffer(1)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    
    float2 size = uniforms.size;
    float2 p = in.texCoord * size;
    
    float thickness = 18.0;
    float index = 1.2;
    float base_height = thickness * 8.0;
    float color_mix = 0.3;
    float4 color_base = uniforms.tintColor; // Use tint color as base
    
    float radius = uniforms.cornerRadius;
    float2 center = size * 0.5;
    float2 rectHalfSize = (size * 0.5) - radius;
    
    rectHalfSize = max(rectHalfSize, 0.0);
    
    float sd = sdfRect(center, rectHalfSize, p, radius);
    
    float3 normal = getNormal(sd, thickness);
    
    float3 incident = float3(0.0, 0.0, -1.0);
    float3 refract_vec = refract(incident, normal, 1.0/index);
    float h = height(sd, thickness);
    
    float refract_length = (h + base_height) / dot(float3(0.0, 0.0, -1.0), refract_vec);
    
    float2 coord1 = p + refract_vec.xy * refract_length;
    
    float2 distortedUV = coord1 / size;
    
    float2 screenUV = uniforms.screenRect.xy + (distortedUV * uniforms.screenRect.zw);
     
    float blurRadius = 3.0; // Adjustable
    float4 bg_col = gaussian_blur(texture, textureSampler, screenUV, blurRadius); // "Refract color"
    
    float alpha = smoothstep(0.0, -1.0, sd); // 0 at 0 distance, 1 at -1 distance (inside)
    float mask = smoothstep(0.0, -1.5, sd); 
    
    float4 refract_color = bg_col;
    float4 reflect_color = float4(0.0);
    // float4 bg_col = bgImage(uv);
    // bg_col.a = smoothstep(-4.,0.,sd);
    
    float4 refract_color = bg_col;

    float3 reflect_vec = reflect(incident, normal);
    float4 reflect_color = float4(0.0);

    float c = clamp(abs(reflect_vec.x - reflect_vec.y), 0.0, 1.0);
    reflect_color = float4(c, c, c, 0.0);

    float mixFactor = (1.0 - normal.z) * 2.0;
    float4 fragColor = mix(mix(refract_color, reflect_color, mixFactor), color_base, color_mix);
    
    fragColor = clamp(fragColor, 0.0, 1.0);
    
    //fragColor.a *= mask;
    return fragColor;
    //return fragColor;
}
