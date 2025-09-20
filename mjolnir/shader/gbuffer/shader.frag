#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool ALBEDO_TEXTURE = false;
layout(constant_id = 2) const bool METALLIC_ROUGHNESS_TEXTURE = false;
layout(constant_id = 3) const bool NORMAL_TEXTURE = false;
layout(constant_id = 4) const bool EMISSIVE_TEXTURE = false;

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP  = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT  = 3;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

struct NodeData {
    uint vertex_offset;
    uint index_offset;
    uint index_count;
    uint material_index;
    uint skin_vertex_offset;
    uint bone_matrix_offset;
    uint flags;
    uint padding;
};

struct MaterialData {
    vec4 base_color_factor;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint normal_texture_index;
    uint emissive_texture_index;
    uint occlusion_texture_index;
    uint material_type;
    uint features_mask;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    float padding;
};

layout(set = 3, binding = 1) readonly buffer NodeBuffer {
    NodeData nodes[];
};

layout(set = 3, binding = 2) readonly buffer MaterialBuffer {
    MaterialData materials[];
};

layout(push_constant) uniform PushConstants {
    uint node_index;
    uint camera_index;
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
    NodeData node = nodes[node_index];
    MaterialData material = materials[node.material_index];

    vec4 albedo;
    if (ALBEDO_TEXTURE) {
        albedo = texture(sampler2D(textures[material.albedo_texture_index], samplers[SAMPLER_LINEAR_REPEAT]), uv);
    } else {
        albedo = color * material.base_color_factor;
    }

    float metallic;
    float roughness;
    if (METALLIC_ROUGHNESS_TEXTURE) {
        vec4 mr = texture(sampler2D(textures[material.metallic_texture_index], samplers[SAMPLER_LINEAR_REPEAT]), uv);
        metallic = mr.b;
        roughness = mr.g;
    } else {
        metallic = material.metallic_value;
        roughness = material.roughness_value;
    }

    vec3 emissive;
    if (EMISSIVE_TEXTURE) {
        emissive = texture(sampler2D(textures[material.emissive_texture_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).rgb;
    } else {
        emissive = vec3(material.emissive_value);
    }

    vec3 N = normalize(normal);
    if (NORMAL_TEXTURE) {
        vec2 encoded_normal = texture(sampler2D(textures[material.normal_texture_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).xy;
        vec2 n_xy = encoded_normal * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        vec3 tangentNormal = vec3(n_xy, n_z);
        vec3 T = normalize(tangent.xyz);
        vec3 B = normalize(cross(N, T)) * tangent.w;
        mat3 TBN = mat3(T, B, N);
        N = normalize(TBN * tangentNormal);
    }
    vec3 normal_encoded = N * 0.5 + 0.5;

    outPosition = vec4(position, 1.0);
    outNormal = vec4(normal_encoded, 1.0);
    outAlbedo = albedo;
    outMetallicRoughness = vec4(metallic, roughness, 0.0, 1.0);
    outEmissive = vec4(emissive, 1.0);
}
