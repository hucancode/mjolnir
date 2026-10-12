#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform PostProcessPushConstant {
    float camera_near;
    float camera_far;
    uint normal_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    float hatch_offset_y;
    // below threshold i, stroke family i darkens the pixel
    float lum_thresholds[4];
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

    vec2 screen_pos = v_uv * vec2(textureSize(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), 0));
    float a = screen_pos.x + screen_pos.y;
    float b = screen_pos.x - screen_pos.y;

    // the two diagonals, then both again shifted by hatch_offset_y
    float strokes[4] = float[4](a, b, a - hatch_offset_y, b - hatch_offset_y);
    float hatched = 1.0;
    for (int i = 0; i < 4; i++) {
        if (lum < lum_thresholds[i] && stroke_mask(strokes[i]) > 0.5) hatched = HATCH_BRIGHTNESS;
    }

    out_color = vec4(color * hatched, rgba.a);
}
