#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 3) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 4) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 5) const uint SAMPLER_LINEAR_REPEAT = 3u;
layout(constant_id = 6) const uint POINT_LIGHT = 0u;
layout(constant_id = 7) const uint DIRECTIONAL_LIGHT = 1u;
layout(constant_id = 8) const uint SPOT_LIGHT = 2u;

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
    float radius;
    float direction; // 0.0 = horizontal, 1.0 = vertical
    float weight_falloff; // Controls Gaussian vs box blur
};

const float MAX_RADIUS = 16.0;

// Optimized Gaussian weight calculation
float gaussian_weight(float distance, float sigma) {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

void main() {
    vec2 texel_size = 1.0 / vec2(textureSize(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), 0));
    vec4 color = vec4(0.0);
    float total_weight = 0.0;
    float blur_radius = clamp(radius, 1.0, MAX_RADIUS);
    float sigma = blur_radius * 0.3; // Gaussian sigma
    vec2 blur_direction = mix(vec2(1.0, 0.0), vec2(0.0, 1.0), direction);
    // Use fewer samples for efficiency - step by 0.5 for smoother results
    for (float i = -blur_radius; i <= blur_radius; i += 0.5) {
        vec2 offset = blur_direction * i * texel_size;
        // Choose between Gaussian and box blur based on weight_falloff
        float weight;
        if (weight_falloff > 0.0) {
            weight = gaussian_weight(i, sigma);
        } else {
            weight = 1.0;
        }
        color += texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv + offset) * weight;
        total_weight += weight;
    }
    out_color = color / total_weight;
}
