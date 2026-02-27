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
    vec3 color;
    float line_width;
};

void main() {
    vec2 texel = 1.0 / vec2(textureSize(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), 0));

    vec4 center_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    vec4 left_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv + vec2(-texel.x * line_width, 0));
    vec4 right_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv + vec2( texel.x * line_width, 0));
    vec4 up_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv + vec2(0,  texel.y * line_width));
    vec4 down_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv + vec2(0, -texel.y * line_width));
    // Simple edge detection using luminance difference with neighbors
    float center = dot(center_color.rgb, vec3(0.299, 0.587, 0.114));
    float threshold = 0.2;

    float left   = dot(left_color.rgb, vec3(0.299, 0.587, 0.114));
    float right  = dot(right_color.rgb, vec3(0.299, 0.587, 0.114));
    float up     = dot(up_color.rgb, vec3(0.299, 0.587, 0.114));
    float down   = dot(down_color.rgb, vec3(0.299, 0.587, 0.114));

    float edge =  smoothstep(threshold, threshold + 0.1, abs(center - left)) +
        smoothstep(threshold, threshold + 0.1, abs(center - right)) +
        smoothstep(threshold, threshold + 0.1, abs(center - up)) +
        smoothstep(threshold, threshold + 0.1, abs(center - down));
    out_color = vec4(mix(center_color.rgb, color, clamp(edge, 0, 1)), 1.0);
}
