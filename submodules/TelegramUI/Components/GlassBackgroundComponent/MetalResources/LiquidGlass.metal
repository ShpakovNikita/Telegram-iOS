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
    float2 touchPos;
    float highlight;
    float padding2;
    float4 iconRect;
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

float2 calculate_refracted_uv(float2 p,
                            float2 size,
                            float radius,
                            float thickness,
                            float index,
                            float base_height) {
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
    return coord1 / size;
}

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
    
    float2 distortedUV = calculate_refracted_uv(p, size, radius, thickness, index, base_height);
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

// Helper Function (Core Logic)
float4 liquid_glass_blur_vertical_core(VertexOut in,
                                       texture2d<float> texture,
                                       constant Uniforms& uniforms) {
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
    
    float4 finalColor;
    
    if (blurRadius < 1.0) {
        float3 outColor = sample.rgb * mask;
        finalColor = float4(mix(outColor, result.rgb * 1.2, result.a), mask);
    } else {
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
        
        float4 blurredColor = totalColor / totalWeight;
        float3 outColor = blurredColor.rgb * mask;
        finalColor = float4(mix(outColor, result.rgb, result.a), mask);
    }
    
    // Highlight
    if (uniforms.highlight > 0.01) {
        float globalBoost = 1.0 + 0.15 * uniforms.highlight;
        
        float d = abs(p.x - uniforms.touchPos.x);
        float radialBoost = smoothstep(400.0, 0.0, d) * 0.2 * uniforms.highlight;
        
        finalColor.rgb *= (globalBoost + radialBoost);
    }
    
    return finalColor;
}

// Entry Point 1: Standard (No MRT)
fragment float4 liquid_glass_blur_vertical(VertexOut in [[stage_in]],
                                           texture2d<float> texture [[texture(0)]],
                                           constant Uniforms& uniforms [[buffer(1)]]) {
    return liquid_glass_blur_vertical_core(in, texture, uniforms);
}

// Entry Point 2: MRT (With Attachment)
struct FragmentOutput {
    float4 color0 [[color(0)]];
    float4 color1 [[color(1)]];
};

fragment FragmentOutput liquid_glass_blur_vertical_mrt(VertexOut in [[stage_in]],
                                           texture2d<float> texture [[texture(0)]],
                                           constant Uniforms& uniforms [[buffer(1)]]) {
    float4 color = liquid_glass_blur_vertical_core(in, texture, uniforms);
    
    FragmentOutput out;
    out.color0 = color;
    out.color1 = color;
    return out;
}

fragment float4 magnifying_glass_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> backgroundTexture [[texture(0)]],
                                       texture2d<float> iconTexture [[texture(1)]],
                                       constant Uniforms &uniforms [[buffer(1)]]) {
    
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    
    float2 size = uniforms.size;
    float2 p = in.texCoord * size;
    float radius = uniforms.cornerRadius;
    
    float thickness = 24.0;
    float index = 1.2;
    float base_height = thickness * 8.0;
    
    // 1. Geometry Calculation (SDF + Normal)
    float2 center = size * 0.5;
    float2 rectHalfSize = (size * 0.5) - radius;
    rectHalfSize = max(rectHalfSize, 0.0);
    
    float sd = sdfRect(center, rectHalfSize, p, radius);
    float3 normal = getNormal(sd, thickness, 1.0);
    float h = height(sd, thickness);
    float3 incident = float3(0.0, 0.0, -1.0);
    
    // 2. Chromatic Aberration Setup
    // Vary index slightly for RGB channels
    float aberration = 0.02;
    float3 indices = float3(index - aberration, index, index + aberration);
    float3 etas = 1.0 / indices;
    
    // Helper to compute refracted UV
    // Metal 2.3+ supports lambdas in some scopes, but keeping it inline or simple is safer here
    // R Channel
    float3 refrR = refract(incident, normal, etas.r);
    float lenR = (h + base_height) / dot(incident, refrR);
    float2 uvR = (p + refrR.xy * lenR) / size;
    
    // G Channel
    float3 refrG = refract(incident, normal, etas.g);
    float lenG = (h + base_height) / dot(incident, refrG);
    float2 uvG = (p + refrG.xy * lenG) / size;
    
    // B Channel
    float3 refrB = refract(incident, normal, etas.b);
    float lenB = (h + base_height) / dot(incident, refrB);
    float2 uvB = (p + refrB.xy * lenB) / size;
    
    
    // 3. Sample Background (RGB separated)
    float r_bg = backgroundTexture.sample(textureSampler, uniforms.screenRect.xy + uvR * uniforms.screenRect.zw).r;
    float g_bg = backgroundTexture.sample(textureSampler, uniforms.screenRect.xy + uvG * uniforms.screenRect.zw).g;
    float b_bg = backgroundTexture.sample(textureSampler, uniforms.screenRect.xy + uvB * uniforms.screenRect.zw).b;
    
    // 4. Sample Icon (RGB separated with scaling)
    float iconScale = uniforms.padding > 0.1 ? uniforms.padding : 1.0;
    
    // Calculate Icon UVs
    float2 iconUvR = uniforms.iconRect.xy + ((uvR - 0.5) / iconScale + 0.5) * uniforms.iconRect.zw;
    float2 iconUvG = uniforms.iconRect.xy + ((uvG - 0.5) / iconScale + 0.5) * uniforms.iconRect.zw;
    float2 iconUvB = uniforms.iconRect.xy + ((uvB - 0.5) / iconScale + 0.5) * uniforms.iconRect.zw;
    
    float4 iconR = iconTexture.sample(textureSampler, iconUvR);
    float4 iconG = iconTexture.sample(textureSampler, iconUvG);
    float4 iconB = iconTexture.sample(textureSampler, iconUvB);
    
    // 5. Mix Per-Channel
    float r = mix(r_bg, iconR.r, iconR.a);
    float g = mix(g_bg, iconG.g, iconG.a);
    float b = mix(b_bg, iconB.b, iconB.a);
    
    float4 content = float4(r, g, b, 1.0);
    
    // 5. Hard Masking for Glass Shape
    if (sd > 0.0) {
        discard_fragment();
    }
    
    return float4(content.rgb, 1.0);
}

fragment float4 simple_copy_fragment(VertexOut in [[stage_in]],
                                     texture2d<float> texture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return texture.sample(textureSampler, in.texCoord);
}
