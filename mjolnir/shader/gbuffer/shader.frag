#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 3) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 4) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 5) const uint SAMPLER_LINEAR_REPEAT = 3u;

const uint FEATURE_ALBEDO_TEXTURE = 1u << 0;
const uint FEATURE_METALLIC_ROUGHNESS_TEXTURE = 1u << 1;
const uint FEATURE_NORMAL_TEXTURE = 1u << 2;
const uint FEATURE_EMISSIVE_TEXTURE = 1u << 3;

struct MaterialData {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint features;
    vec4 base_color_factor;
};

// textures and samplers set = 1
layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

layout(set = 3, binding = 0) readonly buffer MaterialBuffer {
    MaterialData materials[];
};

struct NodeData {
    mat4 world_matrix;
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
};

layout(set = 4, binding = 0) readonly buffer NodeBuffer {
    NodeData nodes[];
};

layout(push_constant) uniform PushConstants {
    uint camera_index;
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;
layout(location = 4) in vec4 tangent;
layout(location = 5) flat in uint node_index;

layout(location = 0) out vec4 outPosition;
layout(location = 1) out vec4 outNormal;
layout(location = 2) out vec4 outAlbedo;
layout(location = 3) out vec4 outMetallicRoughness;
layout(location = 4) out vec4 outEmissive;

void main() {
    NodeData node = nodes[node_index];
    MaterialData material = materials[node.material_id];
    bool has_normal = (material.features & FEATURE_NORMAL_TEXTURE) != 0u;
    bool has_albedo = (material.features & FEATURE_ALBEDO_TEXTURE) != 0u;
    bool has_mr = (material.features & FEATURE_METALLIC_ROUGHNESS_TEXTURE) != 0u;
    bool has_emissive = (material.features & FEATURE_EMISSIVE_TEXTURE) != 0u;

    outPosition = vec4(position, 1.0);
    vec3 N = normalize(normal);
    if (has_normal) {
        vec2 n_xy = texture(
            sampler2D(textures[material.normal_index], samplers[SAMPLER_LINEAR_REPEAT]),
            uv
        ).xy * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        vec3 tangentNormal = vec3(n_xy, n_z);
        vec3 T = normalize(tangent.xyz);
        vec3 B = normalize(cross(N, T)) * tangent.w;
        mat3 TBN = mat3(T, B, N);
        N = normalize(TBN * tangentNormal);
    }
    vec3 normal_encoded = N * 0.5 + 0.5;
    outNormal = vec4(normal_encoded, 1.0);

    vec4 albedo;
    if (has_albedo) {
        albedo = texture(
            sampler2D(textures[material.albedo_index], samplers[SAMPLER_LINEAR_REPEAT]),
            uv
        );
    } else {
        albedo = color * material.base_color_factor;
    }
    outAlbedo = albedo;

    float metallic;
    float roughness;
    if (has_mr) {
        vec4 mr = texture(
            sampler2D(
                textures[material.metallic_roughness_index],
                samplers[SAMPLER_LINEAR_REPEAT]
            ),
            uv
        );
        metallic = mr.b;
        roughness = mr.g;
    } else {
        metallic = material.metallic_value;
        roughness = material.roughness_value;
    }
    outMetallicRoughness = vec4(metallic, roughness, 0.0, 1.0);

    vec3 emissive;
    if (has_emissive) {
        emissive = texture(
            sampler2D(textures[material.emissive_index], samplers[SAMPLER_LINEAR_REPEAT]),
            uv
        ).rgb;
    } else {
        emissive = vec3(material.emissive_value);
    }
    outEmissive = vec4(emissive, 1.0);
}
