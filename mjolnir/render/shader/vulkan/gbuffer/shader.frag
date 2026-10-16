#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

// texture index of a material slot without a texture
const uint NO_TEXTURE = 0u;

struct MaterialData {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint _pad;
    vec4 base_color_factor;
    uint frame_columns;
    uint frame_rows;
    uint frame_index;
    uint _pad0;
};

// textures and samplers set = 1
layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(set = 0, binding = 3) readonly buffer MaterialBuffer {
    MaterialData materials[];
};

struct NodeData {
    mat4 world_matrix;
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
    uint skin_vertex_base; // first of the skinned vertices when skinned
    uint _node_pad[3];
};

layout(set = 0, binding = 1) readonly buffer NodeBuffer {
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

layout(location = 0) out vec4 outNormal;
layout(location = 1) out vec4 outAlbedo;
layout(location = 2) out vec4 outMetallicRoughness;
layout(location = 3) out vec4 outEmissive;

void main() {
    NodeData node = nodes[node_index];
    MaterialData material = materials[node.material_id];
    bool has_normal = material.normal_index != NO_TEXTURE;
    bool has_albedo = material.albedo_index != NO_TEXTURE;
    bool has_mr = material.metallic_roughness_index != NO_TEXTURE;
    bool has_emissive = material.emissive_index != NO_TEXTURE;

    vec3 N = normalize(normal);
    if (has_normal) {
        vec2 n_xy = texture(
            sampler2D(textures[nonuniformEXT(material.normal_index)], samplers[SAMPLER_LINEAR_REPEAT]),
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
            sampler2D(textures[nonuniformEXT(material.albedo_index)], samplers[SAMPLER_LINEAR_REPEAT]),
            uv
        ) * material.base_color_factor;
    } else {
        albedo = color * material.base_color_factor;
    }
    outAlbedo = albedo;

    float metallic;
    float roughness;
    if (has_mr) {
        vec4 mr = texture(
            sampler2D(
                textures[nonuniformEXT(material.metallic_roughness_index)],
                samplers[SAMPLER_LINEAR_REPEAT]
            ),
            uv
        );
        metallic = mr.b * material.metallic_value;
        roughness = mr.g * material.roughness_value;
    } else {
        metallic = material.metallic_value;
        roughness = material.roughness_value;
    }
    outMetallicRoughness = vec4(metallic, roughness, 0.0, 1.0);

    vec3 emissive;
    if (has_emissive) {
        emissive = texture(
            sampler2D(textures[nonuniformEXT(material.emissive_index)], samplers[SAMPLER_LINEAR_REPEAT]),
            uv
        ).rgb * material.emissive_value;
    } else {
        emissive = vec3(material.emissive_value);
    }
    outEmissive = vec4(emissive, 1.0);
}
