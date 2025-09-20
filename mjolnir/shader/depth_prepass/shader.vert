#version 450
layout(constant_id = 0) const bool SKINNED = false;

// Vertex input attributes - same as uber shader
layout(location = 0) in vec3 inPosition;
layout(location = 5) in uvec4 inJoints;
layout(location = 6) in vec4 inWeights;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9]; // Align to 192-byte
};

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

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
};

layout(set = 1, binding = 0) readonly buffer BoneBuffer {
    mat4 bone_matrices[];
};

layout(set = 2, binding = 0) readonly buffer WorldMatrices {
    mat4 world_matrices[];
};

layout(set = 2, binding = 1) readonly buffer NodeBuffer {
    NodeData nodes[];
};

layout(push_constant) uniform PushConstant {
    uint node_index;
    uint camera_index;
};

void main() {
    NodeData node = nodes[node_index];
    Camera camera = cameras[camera_index];
    mat4 world = world_matrices[node_index];
    vec4 modelPos;
    if (SKINNED) {
        uvec4 indices = inJoints + uvec4(node.bone_matrix_offset);
        mat4 skinMatrix =
            inWeights.x * bone_matrices[indices.x] +
            inWeights.y * bone_matrices[indices.y] +
            inWeights.z * bone_matrices[indices.z] +
            inWeights.w * bone_matrices[indices.w];
        modelPos = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPos = vec4(inPosition, 1.0);
    }
    vec4 worldPos = world * modelPos;
    gl_Position = camera.projection * camera.view * worldPos;
}
