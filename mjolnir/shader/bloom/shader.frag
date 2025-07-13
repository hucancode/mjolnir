#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;

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
    float threshold;      // Brightness threshold for bloom
    float intensity;      // Bloom intensity
    float blur_radius;    // Blur radius
    float direction;      // 0.0 = horizontal, 1.0 = vertical
};

const float MAX_RADIUS = 32.0;

float luminance(vec3 color) {
    return dot(color, vec3(0.2126, 0.7152, 0.0722));
}

// Optimized Gaussian weight calculation (same as blur shader)
float gaussian_weight(float distance, float sigma) {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

void main() {
    vec2 texel_size = 1.0 / vec2(textureSize(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), 0));
    vec4 original_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);

    // Normal blur with luminance weighting
    vec4 blur_sum = vec4(0.0);
    float total_weight = 0.0;

    float effective_radius = clamp(blur_radius, 1.0, MAX_RADIUS);
    float sigma = effective_radius * 0.3;
    vec2 blur_direction = mix(vec2(1.0, 0.0), vec2(0.0, 1.0), direction);
    for (float i = -effective_radius; i <= effective_radius; i += 0.5) {
        vec2 offset = blur_direction * i * texel_size;
        vec4 sample_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv + offset);
        float sample_lum = luminance(sample_color.rgb);
        float gaussian_weight_val = gaussian_weight(abs(i), sigma);
        sample_lum = smoothstep(0.0, threshold, sample_lum);
        float final_weight = gaussian_weight_val * sample_lum;
        blur_sum += sample_color * final_weight;
        total_weight += final_weight;
    }
    vec3 bloom_result = blur_sum.rgb * total_weight / effective_radius / 2.0;
    vec3 final_color = original_color.rgb + bloom_result * intensity;

    out_color = vec4(final_color, original_color.a);
}
