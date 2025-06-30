#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool ALBEDO_TEXTURE = false;
layout(constant_id = 2) const bool METALLIC_ROUGHNESS_TEXTURE = false;
layout(constant_id = 3) const bool NORMAL_TEXTURE = false;
layout(constant_id = 4) const bool DISPLACEMENT_TEXTURE = false;
layout(constant_id = 5) const bool EMISSIVE_TEXTURE = false;

const uint MAX_TEXTURES = 50;
const uint MAX_SAMPLERS = 4;
const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;
const uint MAX_LIGHTS = 10;
const uint POINT_LIGHT = 0;
const uint DIRECTIONAL_LIGHT = 1;
const uint SPOT_LIGHT = 2;
const float PI = 3.14159265359;

struct Light {
    mat4 viewProj;
    vec4 color;
    vec4 position;
    vec4 direction;
    uint kind;
    float angle;
    float radius;
    uint hasShadow;
};

layout(set = 0, binding = 0) uniform SceneUniforms {
    mat4 view;
    mat4 proj;
    float time;
};
layout(set = 0, binding = 1) uniform LightUniforms {
    Light lights[MAX_LIGHTS];
    uint lightCount;
};
// layout(set = 0, binding = 2) uniform sampler2D shadowMaps[MAX_LIGHTS];
// layout(set = 0, binding = 3) uniform samplerCube cubeShadowMaps[MAX_LIGHTS];
layout(set = 1, binding = 0) uniform texture2D textures[MAX_TEXTURES];
layout(set = 2, binding = 0) uniform sampler samplers[MAX_SAMPLERS];

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
    float metallic_value;
    float roughness_value;
    float emissive_value;
    float padding;
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;

layout(location = 0) out vec4 outNormal;
layout(location = 1) out vec4 outAlbedo;
layout(location = 2) out vec4 outMetallicRoughness;
layout(location = 3) out vec4 outEmissive;

void main() {
    vec3 N = normalize(normal);
    vec3 normal_encoded = N * 0.5 + 0.5;
    outNormal = vec4(normal_encoded, 1.0);

    vec4 albedo;
    if (ALBEDO_TEXTURE) {
        albedo = texture(sampler2D(textures[albedo_index], samplers[SAMPLER_LINEAR_REPEAT]), uv);
    } else {
        albedo = color;
    }
    outAlbedo = albedo;

    float metallic;
    float roughness;
    if (METALLIC_ROUGHNESS_TEXTURE) {
        vec4 mr = texture(sampler2D(textures[metallic_roughness_index], samplers[SAMPLER_LINEAR_REPEAT]), uv);
        metallic = mr.b;
        roughness = mr.g;
    } else {
        metallic = metallic_value;
        roughness = roughness_value;
    }
    outMetallicRoughness = vec4(metallic, roughness, 0.0, 1.0);
    vec3 emissive;
    if (EMISSIVE_TEXTURE) {
        emissive = texture(sampler2D(textures[emissive_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).rgb;
    } else {
        emissive = vec3(emissive_value);
    }
    outEmissive = vec4(emissive, 1.0);
}
