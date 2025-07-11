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
    uint gbuffer_position_index;
    uint gbuffer_normal_index;
    uint gbuffer_albedo_index;
    uint gbuffer_metallic_index;
    uint gbuffer_emissive_index;
    uint gbuffer_depth_index;
    uint input_image_index;
    vec2 resolution;
    float hatch_offset_y;
    float lum_threshold_01;
    float lum_threshold_02;
    float lum_threshold_03;
    float lum_threshold_04;
};

const float EPSILON = 1.0;
const float HATCH_BRIGHTNESS = 0.7; // lesser means darker, more pronounced hatching
const float EDGE_SENSITIVITY = 0.3; // lesser means less edge detected

// Camera parameters - these should match camera setup
// TODO: move those to uniform buffer
const float near_plane = 0.1;
const float far_plane = 50.0;

float linearize_depth(float depth) {
    float z = depth * 2.0 - 1.0; // Back to NDC
    return (2.0 * near_plane * far_plane) / (far_plane + near_plane - z * (far_plane - near_plane));
}

vec3 edge() {
    vec2 texel_size = 1.0 / vec2(textureSize(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), 0));

    // Sobel kernels
    float kernelX[9] = float[](
        -1.0, -2.0, -1.0,
         0.0,  0.0,  0.0,
         1.0,  2.0,  1.0
    );
    float kernelY[9] = float[](
        -1.0,  0.0,  1.0,
        -2.0,  0.0,  2.0,
        -1.0,  0.0,  1.0
    );
    vec2 offset[9] = vec2[](
        vec2(-1, -1), vec2(0, -1), vec2(1, -1),
        vec2(-1,  0), vec2(0,  0), vec2(1,  0),
        vec2(-1,  1), vec2(0,  1), vec2(1,  1)
    );

    // Normal Sobel
    vec3 sumX_normal = vec3(0.0);
    vec3 sumY_normal = vec3(0.0);

    // Depth Sobel
    float sumX_depth = 0.0;
    float sumY_depth = 0.0;
    float center_depth = linearize_depth(texture(sampler2D(textures[gbuffer_depth_index], samplers[SAMPLER_NEAREST_CLAMP]), v_uv).r);

    for (int i = 0; i < 9; ++i) {
        vec2 uv_offset = v_uv + offset[i] * texel_size;
        vec3 normal = texture(sampler2D(textures[gbuffer_normal_index], samplers[SAMPLER_NEAREST_CLAMP]), uv_offset).rgb;
        sumX_normal += normal * kernelX[i];
        sumY_normal += normal * kernelY[i];

        float depth = linearize_depth(texture(sampler2D(textures[gbuffer_depth_index], samplers[SAMPLER_NEAREST_CLAMP]), uv_offset).r);
        sumX_depth += (depth - center_depth) * kernelX[i];
        sumY_depth += (depth - center_depth) * kernelY[i];
    }

    float edge_strength_normal = length(sumX_normal) + length(sumY_normal);
    float k_normal = clamp(edge_strength_normal * EDGE_SENSITIVITY, 0.0, 1.0);

    float edge_strength_depth = sqrt(sumX_depth * sumX_depth + sumY_depth * sumY_depth) * 0.5;
    float k_depth = clamp(edge_strength_depth * EDGE_SENSITIVITY, 0.0, 1.0);

    float k = max(k_normal, k_depth);
    return vec3(k);
}

vec3 hatch() {
    vec3 color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv).rgb;

    float lum = length(color) / sqrt(3.0);
    float ret = 1.0;

    vec2 screen_pos = v_uv * resolution;

    if (lum < lum_threshold_01) {
        if (mod(screen_pos.x + screen_pos.y, 10.0) < EPSILON) ret = HATCH_BRIGHTNESS;
    }

    if (lum < lum_threshold_02) {
        if (mod(screen_pos.x - screen_pos.y, 10.0) < EPSILON) ret = HATCH_BRIGHTNESS;
    }

    if (lum < lum_threshold_03) {
        if (mod(screen_pos.x + screen_pos.y - hatch_offset_y, 10.0) < EPSILON) ret = HATCH_BRIGHTNESS;
    }

    if (lum < lum_threshold_04) {
        if (mod(screen_pos.x - screen_pos.y - hatch_offset_y, 10.0) < EPSILON) ret = HATCH_BRIGHTNESS;
    }

    return vec3(ret);
}

void main() {
    vec4 rgba = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    vec3 color = rgba.rgb;
    // Apply edge detection using the normal buffer (darkens edges)
    color *= 1.0 - max(edge(), 0.4);
    // Apply cross-hatching pattern
    color *= hatch();
    out_color = vec4(color, rgba.a);
}
