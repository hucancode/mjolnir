#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 3) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 4) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 5) const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];
layout(set = 0, binding = 2) uniform textureCube textures_cube[];

layout(push_constant) uniform PostProcessPushConstant {
    uint position_texture_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint original_image_index;
    float threshold;
    float intensity;
    float blur_radius;
    float direction;
};

const float MAX_RADIUS = 64.0;

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

float gaussian_weight(float distance, float sigma) {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

// UE4/Karis soft-knee bright-pass. Smooth transition around threshold avoids
// hard cutoff that creates ringing and amplitude cliffs.
vec3 soft_brightpass(vec3 c, float lum, float threshold) {
    float knee = threshold * 0.5;
    float soft = clamp(lum - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contribution = max(soft, lum - threshold) / max(lum, 1e-4);
    return c * contribution;
}

void main() {
    vec2 texel_size = 1.0 / vec2(textureSize(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), 0));
    float effective_radius = clamp(blur_radius, 1.0, MAX_RADIUS);
    // 3-sigma rule: kernel must decay to ~0 by the loop edge, otherwise
    // truncated separable Gaussian leaves a square box artifact (visible as
    // square halos). sigma = radius/3 keeps the iso-weight contour circular.
    float sigma = effective_radius / 3.0;
    vec2 dir = mix(vec2(1.0, 0.0), vec2(0.0, 1.0), direction);
    bool is_horizontal = direction < 0.5;

    vec3 acc = vec3(0.0);
    float total = 0.0;
    for (float i = -effective_radius; i <= effective_radius; i += 1.0) {
        vec2 offset = dir * i * texel_size;
        vec3 c = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv + offset).rgb;
        if (is_horizontal) {
            float lum = luminance(c);
            c = soft_brightpass(c, lum, threshold);
        }
        float w = gaussian_weight(i, sigma);
        acc += c * w;
        total += w;
    }
    vec3 blurred = acc / total;

    vec3 final_color;
    if (is_horizontal) {
        final_color = blurred;
    } else {
        vec3 orig = texture(sampler2D(textures[original_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv).rgb;
        // Soft additive: blur amplitude attenuates where original already
        // bright. Prevents saturation runaway when intensity raised.
        vec3 boost = blurred * intensity;
        final_color = orig + boost / (1.0 + 0.25 * boost);
    }
    out_color = vec4(final_color, 1.0);
}
