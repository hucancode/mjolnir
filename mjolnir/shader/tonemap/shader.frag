#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint MAX_SAMPLERS = 1u;
layout(constant_id = 3) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 4) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 5) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 6) const uint SAMPLER_LINEAR_REPEAT = 3u;
layout(constant_id = 7) const uint POINT_LIGHT = 0u;
layout(constant_id = 8) const uint DIRECTIONAL_LIGHT = 1u;
layout(constant_id = 9) const uint SPOT_LIGHT = 2u;

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
    float exposure;
    float gamma;
};

void main() {
    vec3 color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv).rgb;
    // Simple Reinhard tonemapping
    color = vec3(1.0) - exp(-color * exposure);
    color = pow(color, vec3(1.0 / gamma));
    out_color = vec4(color, 1.0);
}
