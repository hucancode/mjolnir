#version 450

layout(location = 0) out vec4 outColor;
layout(location = 0) flat in uint node_index;

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

layout(set = 3, binding = 0) readonly buffer MaterialBuffer {
    MaterialData materials[];
};

struct NodeData {
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
};

layout(set = 5, binding = 0) readonly buffer NodeBuffer {
    NodeData nodes[];
};

layout(push_constant) uniform PushConstants {
    uint camera_index;
};

void main() {
    NodeData node = nodes[node_index];
    MaterialData material = materials[node.material_id];
    outColor = material.base_color_factor;
}
