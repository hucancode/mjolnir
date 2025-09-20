#version 450

layout(constant_id = 0) const bool SKINNED = false;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inTangent;
layout(location = 3) in vec2 inTexCoord;
layout(location = 4) in vec4 inColor;
layout(location = 5) in uvec4 inJointIndices;
layout(location = 6) in vec4 inJointWeights;

// Output to fragment shader
layout(location = 0) out vec4 outColor;

// Camera structure
struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9]; // Align to 192-byte
};

// Bindless camera buffer set = 0
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

// Bone matrices
layout(set = 2, binding = 0) readonly buffer BoneMatrices {
    mat4 matrices[];
} boneMatrices;

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

layout(set = 3, binding = 0) readonly buffer WorldMatrices {
    mat4 world_matrices[];
};

layout(set = 3, binding = 1) readonly buffer NodeBuffer {
    NodeData nodes[];
};

layout(push_constant) uniform PushConstants {
    uint node_index;
    uint camera_index;
};


void main() {
    // Get camera from bindless buffer
    NodeData node = nodes[node_index];
    Camera camera = camera_buffer.cameras[camera_index];
    mat4 world = world_matrices[node_index];

    // Calculate position based on skinning
    vec4 modelPosition;
    if (SKINNED) {
        uint baseOffset = node.bone_matrix_offset;
        mat4 skinMatrix =
            inJointWeights.x * boneMatrices.matrices[baseOffset + inJointIndices.x] +
            inJointWeights.y * boneMatrices.matrices[baseOffset + inJointIndices.y] +
            inJointWeights.z * boneMatrices.matrices[baseOffset + inJointIndices.z] +
            inJointWeights.w * boneMatrices.matrices[baseOffset + inJointIndices.w];

        modelPosition = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPosition = vec4(inPosition, 1.0);
    }
    // Transform to world space
    vec4 worldPos = world * modelPosition;
    // Pass color to fragment shader
    outColor = inColor;
    // Calculate final position
    gl_Position = camera.projection * camera.view * worldPos;
}
