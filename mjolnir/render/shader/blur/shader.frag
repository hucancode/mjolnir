#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform PostProcessPushConstant {
    float camera_near;
    float camera_far;
    uint normal_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint original_image_index;
    uint pass; // 0 = horizontal, 1 = vertical
    uint _pad0;
    float radius;
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
    vec2 blur_direction = pass == 0u ? vec2(1.0, 0.0) : vec2(0.0, 1.0);
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
