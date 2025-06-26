#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const bool SKINNED = false;

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
// Shadow maps removed - not used in G-buffer pass
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
    uint padding[1];
} pc;

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;
layout(location = 0) out vec4 outColor;

void main() {
    // Output world-space normals encoded in 0-1 range
    vec3 N = normalize(normal);
    vec3 normal_encoded = N * 0.5 + 0.5;
    outColor = vec4(normal_encoded, 1.0);
}
