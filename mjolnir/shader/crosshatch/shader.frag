#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;
layout(set = 0, binding = 1) uniform sampler2D u_normal_texture;
layout(set = 0, binding = 2) uniform sampler2D u_depth_texture;

layout(push_constant) uniform CrossHatchParams {
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

vec3 edge() {
    vec2 texel_size = 1.0 / resolution;

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
    float center_depth = texture(u_depth_texture, v_uv).r;

    for (int i = 0; i < 9; ++i) {
        vec2 uv_offset = v_uv + offset[i] * texel_size;
        vec3 normal = texture(u_normal_texture, uv_offset).rgb;
        sumX_normal += normal * kernelX[i];
        sumY_normal += normal * kernelY[i];

        float depth = texture(u_depth_texture, uv_offset).r;
        sumX_depth += (depth - center_depth) * kernelX[i];
        sumY_depth += (depth - center_depth) * kernelY[i];
    }

    float edge_strength_normal = length(sumX_normal) + length(sumY_normal);
    float k_normal = clamp(edge_strength_normal * EDGE_SENSITIVITY, 0.0, 1.0);

    float edge_strength_depth = sqrt(sumX_depth * sumX_depth + sumY_depth * sumY_depth) * 200.0;
    float k_depth = clamp(edge_strength_depth * EDGE_SENSITIVITY, 0.0, 1.0);

    float k = max(k_normal, k_depth);
    return vec3(k);
}

vec3 hatch() {
    vec3 color = texture(u_input_image, v_uv).rgb;
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
    vec3 color = texture(u_input_image, v_uv).rgb;
    // Apply edge detection using the normal buffer (darkens edges)
    color *= 1.0 - max(edge(), 0.4);
    // Apply cross-hatching pattern
    color *= hatch();
    float alpha = texture(u_input_image, v_uv).a;
    out_color = vec4(color, alpha);
}
