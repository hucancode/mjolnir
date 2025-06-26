#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;
layout(set = 0, binding = 1) uniform sampler2D u_normal_texture;

layout(push_constant) uniform CrossHatchParams {
    vec2 resolution;
    float hatch_offset_y;
    float lum_threshold_01;
    float lum_threshold_02;
    float lum_threshold_03;
    float lum_threshold_04;
};

const float EPSILON = 1.0;

vec3 edge() {
    vec2 texel_size = 1.0 / resolution;

    // Sobel operator for edge detection on normals
    vec4 horiz_edge = vec4(0.0);
    horiz_edge -= texture(u_normal_texture, v_uv + vec2(-texel_size.x, -texel_size.y)) * 1.0;
    horiz_edge -= texture(u_normal_texture, v_uv + vec2(-texel_size.x, 0.0)) * 2.0;
    horiz_edge -= texture(u_normal_texture, v_uv + vec2(-texel_size.x, texel_size.y)) * 1.0;
    horiz_edge += texture(u_normal_texture, v_uv + vec2(texel_size.x, -texel_size.y)) * 1.0;
    horiz_edge += texture(u_normal_texture, v_uv + vec2(texel_size.x, 0.0)) * 2.0;
    horiz_edge += texture(u_normal_texture, v_uv + vec2(texel_size.x, texel_size.y)) * 1.0;

    vec4 vert_edge = vec4(0.0);
    vert_edge -= texture(u_normal_texture, v_uv + vec2(-texel_size.x, -texel_size.y)) * 1.0;
    vert_edge -= texture(u_normal_texture, v_uv + vec2(0.0, -texel_size.y)) * 2.0;
    vert_edge -= texture(u_normal_texture, v_uv + vec2(texel_size.x, -texel_size.y)) * 1.0;
    vert_edge += texture(u_normal_texture, v_uv + vec2(-texel_size.x, texel_size.y)) * 1.0;
    vert_edge += texture(u_normal_texture, v_uv + vec2(0.0, texel_size.y)) * 2.0;
    vert_edge += texture(u_normal_texture, v_uv + vec2(texel_size.x, texel_size.y)) * 1.0;

    vec3 edge_strength = sqrt((horiz_edge.rgb * horiz_edge.rgb) + (vert_edge.rgb * vert_edge.rgb));
    float k = clamp(edge_strength.r + edge_strength.g + edge_strength.b, 0.0, 1.0);
    return vec3(k);
}

vec3 hatch() {
    vec3 color = texture(u_input_image, v_uv).rgb;
    float lum = length(color) / sqrt(3.0);
    float ret = 1.0;

    vec2 screen_pos = v_uv * resolution;

    if (lum < lum_threshold_01) {
        if (mod(screen_pos.x + screen_pos.y, 10.0) < EPSILON) ret = 0.0;
    }

    if (lum < lum_threshold_02) {
        if (mod(screen_pos.x - screen_pos.y, 10.0) < EPSILON) ret = 0.0;
    }

    if (lum < lum_threshold_03) {
        if (mod(screen_pos.x + screen_pos.y - hatch_offset_y, 10.0) < EPSILON) ret = 0.0;
    }

    if (lum < lum_threshold_04) {
        if (mod(screen_pos.x - screen_pos.y - hatch_offset_y, 10.0) < EPSILON) ret = 0.0;
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
