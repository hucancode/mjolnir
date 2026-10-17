#version 450

layout(location = 0) out vec4 outColor;
layout(location = 5) flat in uint node_index;

struct Material {
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

layout(set = 0, binding = 3) readonly buffer MaterialBuffer {
    Material materials[];
};

struct Node {
    mat4 world_matrix;
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
    uint skin_vertex_base; // first of the skinned vertices when skinned
    uint _node_pad[3];
};

layout(set = 0, binding = 1) readonly buffer NodeBuffer {
    Node nodes[];
};

layout(push_constant) uniform MeshPush {
    uint camera_index;
};

// Simple hash function for pseudo-random color generation
float hash(uint x) {
    x = ((x >> 16) ^ x) * 0x45d9f3bu;
    x = ((x >> 16) ^ x) * 0x45d9f3bu;
    x = (x >> 16) ^ x;
    return float(x) / 4294967295.0;
}

vec3 hsv_to_rgb(vec3 hsv) {
    vec3 rgb = clamp(abs(mod(hsv.x * 6.0 + vec3(0.0, 4.0, 2.0), 6.0) - 3.0) - 1.0, 0.0, 1.0);
    return hsv.z * mix(vec3(1.0), rgb, hsv.y);
}

void main() {
    Node node = nodes[node_index];
    Material material = materials[node.material_id];

    uint seed = uint(gl_PrimitiveID) ^ (node_index * 2654435761u);
    float h = hash(seed);
    float s = 0.7 + hash(seed + 1u) * 0.3;
    float v = 0.8 + hash(seed + 2u) * 0.2;
    vec3 rgb = hsv_to_rgb(vec3(h, s, v));
    outColor = vec4(rgb, material.base_color_factor.a);
}
