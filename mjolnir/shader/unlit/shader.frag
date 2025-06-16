#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint MAX_TEXTURES = 50;
const uint MAX_SAMPLERS = 4;
const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool HAS_ALBEDO_TEXTURE = false;

layout(set = 0, binding = 0) uniform SceneUniforms {
    mat4 view;
    mat4 proj;
    float time;
};

layout(set = 1, binding = 0) uniform texture2D textures[MAX_TEXTURES];
layout(set = 2, binding = 0) uniform sampler samplers[MAX_SAMPLERS];
// layout(set = 4, binding = 0) uniform MaterialFallbacks {
//     vec4 albedoValue;
// };

layout(push_constant) uniform PushConstants {
    mat4 world;
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint displacement_index;
    uint emissive_index;
    uint environment_index;
    uint brdf_lut_index;
    uint bone_matrix_offset;
} pc;

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec2 uv;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = HAS_ALBEDO_TEXTURE ? texture(sampler2D(textures[pc.albedo_index], samplers[SAMPLER_LINEAR_REPEAT]), uv) : color;
}
