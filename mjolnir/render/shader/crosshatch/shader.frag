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
    uint _pad;
    vec2 resolution;
    float hatch_offset_y;
    float lum_threshold_01;
    float lum_threshold_02;
    float lum_threshold_03;
    float lum_threshold_04;
};

const float HATCH_BRIGHTNESS = 0.35;
const float STROKE_WIDTH = 1.5;
const float STROKE_SPACING = 10.0;

float stroke_mask(float coord) {
    float m = mod(coord, STROKE_SPACING);
    return step(m, STROKE_WIDTH);
}

void main() {
    vec4 rgba = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    vec3 color = rgba.rgb;

    // Tonemap luminance into [0,1] so HDR scenes still hatch dark regions correctly.
    float raw_lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
    float lum = raw_lum / (raw_lum + 1.0);

    vec2 screen_pos = v_uv * resolution;
    float a = screen_pos.x + screen_pos.y;
    float b = screen_pos.x - screen_pos.y;

    float hatched = 1.0;
    if (lum < lum_threshold_01 && stroke_mask(a) > 0.5) hatched = HATCH_BRIGHTNESS;
    if (lum < lum_threshold_02 && stroke_mask(b) > 0.5) hatched = HATCH_BRIGHTNESS;
    if (lum < lum_threshold_03 && stroke_mask(a - hatch_offset_y) > 0.5) hatched = HATCH_BRIGHTNESS;
    if (lum < lum_threshold_04 && stroke_mask(b - hatch_offset_y) > 0.5) hatched = HATCH_BRIGHTNESS;

    out_color = vec4(color * hatched, rgba.a);
}
