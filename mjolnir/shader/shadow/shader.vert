#version 450

layout(constant_id = 0) const bool SKINNED = false;

layout(location = 0) in vec3 inPosition;
layout(location = 5) in uvec4 inJoints;
layout(location = 6) in vec4 inWeights;

layout(location = 0) out vec3 worldPos;

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

layout(set = 1, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

layout(set = 2, binding = 0) readonly buffer WorldMatrices {
    mat4 world_matrices[];
};

layout(set = 2, binding = 1) readonly buffer NodeBuffer {
    NodeData nodes[];
};

layout(push_constant) uniform PushConstants {
    uint node_index;
    uint camera_index;
};

void main() {
    NodeData node = nodes[node_index];
    Camera camera = cameras[camera_index];
    mat4 world = world_matrices[node_index];
    vec4 modelPosition;
    if (SKINNED) {
        uvec4 indices = inJoints + uvec4(node.bone_matrix_offset);
        mat4 skinMatrix =
            inWeights.x * bones[indices.x] +
            inWeights.y * bones[indices.y] +
            inWeights.z * bones[indices.z] +
            inWeights.w * bones[indices.w];
        modelPosition = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPosition = vec4(inPosition, 1.0);
    }
    vec4 worldPosition = world * modelPosition;
    worldPos = worldPosition.xyz;
    gl_Position = camera.projection * camera.view * worldPosition;
}
