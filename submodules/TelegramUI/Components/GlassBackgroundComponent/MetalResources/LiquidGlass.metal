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

float3 getNormal(float sd, float thickness, float direction) {
    float dx = dfdx(sd);
    float dy = dfdy(sd);

    float n_cos = max(thickness + sd, 0.0) / thickness;
    float n_sin = sqrt(1.0 - n_cos * n_cos);

    return normalize(float3(direction * dx * n_cos, dy * n_cos, n_sin));
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

fragment float4 liquid_glass_fragment(VertexOut in [[stage_in]],
                                      texture2d<float> texture [[texture(0)]],
                                      constant Uniforms &uniforms [[buffer(1)]]);

float4 glass_content_shade(float2 p,
                   float2 size,
                   float radius, 
                   float thickness, 
                   float index, 
                   float base_height, 
                   float4 color_base, 
                   float color_mix, 
                   constant Uniforms& uniforms, 
                   texture2d<float> texture, 
                   sampler textureSampler) {
    float2 center = size * 0.5;
    float2 rectHalfSize = (size * 0.5) - radius;
    rectHalfSize = max(rectHalfSize, 0.0);
    
    float sd = sdfRect(center, rectHalfSize, p, radius);
    
    float3 normal = getNormal(sd, thickness, 1.0);
    
    float3 incident = float3(0.0, 0.0, -1.0);
    float3 refract_vec = refract(incident, normal, 1.0/index);
    float h = height(sd, thickness);
    
    float refract_length = (h + base_height) / dot(incident, refract_vec);
    
    float2 coord1 = p + refract_vec.xy * refract_length;
    float2 distortedUV = coord1 / size;
    float2 screenUV = uniforms.screenRect.xy + (distortedUV * uniforms.screenRect.zw);
    
    float4 bg_col = texture.sample(textureSampler, screenUV);
    
    return mix(bg_col, color_base, color_mix);
}

float4 glass_border_shade(float2 p,
                   float2 size,
                   float radius,
                   float thickness,
                   float index,
                   float base_height,
                   float4 color_base,
                   float color_mix,
                   constant Uniforms& uniforms,
                   texture2d<float> texture,
                   sampler textureSampler) {
    float2 center = size * 0.5;
    float2 rectHalfSize = (size * 0.5) - radius;
    rectHalfSize = max(rectHalfSize, 0.0);
    
    float sd = sdfRect(center, rectHalfSize, p, radius);
    if (sd > thickness)
    {
        return float4(0.0);
    }
    
    float3 normal = getNormal(sd, thickness, -1.0);
    
    float3 incident = float3(0.0, 0.0, -1.0);
    float3 refract_vec = refract(incident, normal, 1.0/index);
    float h = height(sd, thickness);
    
    float refract_length = (h + base_height) / dot(incident, refract_vec);
    
    float2 coord1 = p + refract_vec.xy * refract_length;
    float2 distortedUV = coord1 / size;
    float2 screenUV = uniforms.screenRect.xy + (distortedUV * uniforms.screenRect.zw);
    
    float4 bg_col = texture.sample(textureSampler, screenUV);
    float3 reflect_vec = reflect(incident, normal);
    float c = clamp(abs(reflect_vec.x - reflect_vec.y), 0.0, 1.0);
    
    float4 targetColor = mix(bg_col, color_base, color_mix);
    return float4(targetColor.rgb, c);
}

// Pass 1: Compose the raw glass effect (Refraction, Reflection, Lighting)
fragment float4 liquid_glass_compose(VertexOut in [[stage_in]],
                                      texture2d<float> texture [[texture(0)]],
                                      constant Uniforms& uniforms [[buffer(1)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    
    float2 size = uniforms.size;
    float2 p = in.texCoord * size;
    
    float thickness = 24.0;
    float index = 1.2;
    float base_height = thickness * 8.0;
    float color_mix = 0.85;
    float4 color_base = uniforms.tintColor;
    float radius = uniforms.cornerRadius;
    
    float4 result = glass_content_shade(p, size, radius, thickness, index, base_height, color_base, color_mix, uniforms, texture, textureSampler);
    
    return result; 
}

// Pass 2: Horizontal Blur
fragment float4 liquid_glass_blur_horizontal(VertexOut in [[stage_in]],
                                             texture2d<float> texture [[texture(0)]],
                                             constant Uniforms& uniforms [[buffer(1)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    
    float2 size = uniforms.size;
    float2 p = in.texCoord * size;
    float radius = uniforms.cornerRadius;
    
    // Calculate SDF locally for variable blur
    float2 center = size * 0.5;
    float2 rectHalfSize = (size * 0.5) - radius;
    rectHalfSize = max(rectHalfSize, 0.0);
    float4 sample = texture.sample(textureSampler, in.texCoord);
    float sd = sdfRect(center, rectHalfSize, p, radius);
    
    float blurFactor = 0.2 + smoothstep(0.0, -155.0, sd) * 0.8;
    float blurRadius = 4.0 * blurFactor; // Max radius
    
    if (blurRadius < 1.0) {
        return sample;
    }
    
    float4 totalColor = float4(0.0);
    float totalWeight = 0.0;
    
    // 7-tap 1D Gaussian (Horizontal)
    for (float i = -3.0; i <= 3.0; i += 1.0) {
        float offset = i * blurRadius;
        float weight = exp(-(i*i) / 8.0); // Sigma^2 * 2 = 4.0 * 2 = 8.0
        
        float2 uvOffset = float2(offset / size.x, 0.0);
        totalColor += texture.sample(textureSampler, in.texCoord + uvOffset) * weight;
        totalWeight += weight;
    }
    
    return totalColor / totalWeight;
}

// Pass 3: Vertical Blur
fragment float4 liquid_glass_blur_vertical(VertexOut in [[stage_in]],
                                           texture2d<float> texture [[texture(0)]],
                                           constant Uniforms& uniforms [[buffer(1)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    
    float2 size = uniforms.size;
    float2 p = in.texCoord * size;
    float radius = uniforms.cornerRadius;
    
    float thickness = 4.0;
    float index = 1.2;
    float base_height = thickness * 8.0;
    float color_mix = 0.8;
    float4 color_base = uniforms.tintColor + float4(0.2);
    
    // Calculating sharp edge appearance
    float4 result = glass_border_shade(p, size, radius, thickness, index, base_height, color_base, color_mix, uniforms, texture, textureSampler);
    
    float2 center = size * 0.5;
    float2 rectHalfSize = (size * 0.5) - radius;
    rectHalfSize = max(rectHalfSize, 0.0);
    float4 sample = texture.sample(textureSampler, in.texCoord);
    float sd = sdfRect(center, rectHalfSize, p, radius);
    
    float blurFactor = 0.2 + smoothstep(0.0, -155.0, sd) * 0.8;
    float blurRadius = 4.0 * blurFactor;
    
    float mask = smoothstep(0.0, -1.5, sd);
    
    if (blurRadius < 1.0) {
        float3 outColor = sample.rgb * mask;
        return float4(mix(outColor, result.rgb * 1.2, result.a), mask);
    }
    
    float4 totalColor = float4(0.0);
    float totalWeight = 0.0;
    
    // 7-tap 1D Gaussian (Vertical)
    for (float i = -3.0; i <= 3.0; i += 1.0) {
        float offset = i * blurRadius;
        float weight = exp(-(i*i) / 8.0);
        
        float2 uvOffset = float2(0.0, offset / size.y);
        totalColor += texture.sample(textureSampler, in.texCoord + uvOffset) * weight;
        totalWeight += weight;
    }
    
    float4 finalColor = totalColor / totalWeight;
    
    float3 outColor = finalColor.rgb * mask;
    return float4(mix(outColor, result.rgb, result.a), mask);
}
