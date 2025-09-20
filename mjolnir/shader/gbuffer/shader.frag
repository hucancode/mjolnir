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

// Material buffer set = 3
struct MaterialData {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint material_type;
    uint features;
    vec4 base_color_factor;
    uint padding[2];
};

layout(set = 3, binding = 0) readonly buffer MaterialBuffer {
    MaterialData materials[];
};

// NodeData structure (must match Odin struct)
struct NodeData {
    uint material_id;
    uint mesh_id;
    uint bone_matrix_offset;
    uint _padding;
};

// NEW: NodeData buffer (set 5)
layout(set = 5, binding = 0) readonly buffer NodeDataBuffer {
    NodeData node_data[];
};

// Push constant budget: 128 bytes - simplified for indirect drawing
layout(push_constant) uniform PushConstants {
    uint camera_index;     // 4
    uint padding[31];      // 124
};


layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;
layout(location = 4) in vec4 tangent;
layout(location = 5) flat in uint nodeId;

layout(location = 0) out vec4 outPosition;
layout(location = 1) out vec4 outNormal;
layout(location = 2) out vec4 outAlbedo;
layout(location = 3) out vec4 outMetallicRoughness;
layout(location = 4) out vec4 outEmissive;

void main() {
    // Get node data using node_id passed from vertex shader
    // Bounds check to prevent GPU crashes
    if (nodeId >= node_data.length()) {
        discard;
        return;
    }

    NodeData node = node_data[nodeId];

    // Bounds check material access
    if (node.material_id >= materials.length()) {
        discard;
        return;
    }

    MaterialData material = materials[node.material_id];

    outPosition = vec4(position, 1.0);
    vec3 N = normalize(normal);
    if (NORMAL_TEXTURE) {
        // Sample tangent-space normal from normal map (BC5/XY: .xy, reconstruct z)
        vec2 n_xy = texture(sampler2D(textures[material.normal_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).xy * 2.0 - 1.0;
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
        albedo = texture(sampler2D(textures[material.albedo_index], samplers[SAMPLER_LINEAR_REPEAT]), uv);
        albedo *= material.base_color_factor;
    } else {
        albedo = color * material.base_color_factor;
    }
    outAlbedo = albedo;

    float metallic;
    float roughness;
    if (METALLIC_ROUGHNESS_TEXTURE) {
        vec4 mr = texture(sampler2D(textures[material.metallic_roughness_index], samplers[SAMPLER_LINEAR_REPEAT]), uv);
        metallic = mr.b * material.metallic_value;
        roughness = mr.g * material.roughness_value;
    } else {
        metallic = material.metallic_value;
        roughness = material.roughness_value;
    }
    outMetallicRoughness = vec4(metallic, roughness, 0.0, 1.0);
    vec3 emissive;
    if (EMISSIVE_TEXTURE) {
        emissive = texture(sampler2D(textures[material.emissive_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).rgb * material.emissive_value;
    } else {
        emissive = vec3(material.emissive_value);
    }
    outEmissive = vec4(emissive, 1.0);
}
