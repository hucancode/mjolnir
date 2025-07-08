#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool ALBEDO_TEXTURE = false;
layout(constant_id = 2) const bool METALLIC_ROUGHNESS_TEXTURE = false;
layout(constant_id = 3) const bool NORMAL_TEXTURE = false;
layout(constant_id = 4) const bool EMISSIVE_TEXTURE = false;

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;

// textures and samplers set = 1
layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

// Push constant budget: 128 bytes
layout(push_constant) uniform PushConstants {
    mat4 world;            // 64 bytes
    uint bone_matrix_offset; // 4
    uint albedo_index;     // 4
    uint metallic_roughness_index; // 4
    uint normal_index;     // 4
    uint emissive_index;   // 4
    float metallic_value;  // 4
    float roughness_value; // 4
    float emissive_value;  // 4
    float padding[4];        // 12 (pad to 128)
};


layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;
layout(location = 4) in vec4 tangent;

layout(location = 0) out vec4 outPosition;
layout(location = 1) out vec4 outNormal;
layout(location = 2) out vec4 outAlbedo;
layout(location = 3) out vec4 outMetallicRoughness;
layout(location = 4) out vec4 outEmissive;

void main() {
    outPosition = vec4(position, 1.0);
    vec3 N = normalize(normal);
    if (NORMAL_TEXTURE) {
        // Sample tangent-space normal from normal map (BC5/XY: .xy, reconstruct z)
        vec2 n_xy = texture(sampler2D(textures[normal_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).xy * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        vec3 tangentNormal = vec3(n_xy, n_z);
        // Reconstruct TBN matrix
        vec3 T = normalize(tangent.xyz);
        vec3 B = normalize(cross(N, T)) * tangent.w;
        mat3 TBN = mat3(T, B, N);
        N = normalize(TBN * tangentNormal);
    }
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
