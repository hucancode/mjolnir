#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inTangent;
layout(location = 3) in vec2 inTexCoord;
layout(location = 4) in vec4 inColor;

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

layout(set = 4, binding = 0) readonly buffer WorldMatrices {
    mat4 world_matrices[];
};

struct NodeData {
    uint material_id;
    uint mesh_id;
    uint bone_matrix_offset;
    uint _padding;
};

layout(set = 5, binding = 0) readonly buffer NodeBuffer {
    NodeData nodes[];
};

struct MeshData {
    vec3 aabb_min;
    uint is_skinned;
    vec3 aabb_max;
    uint vertex_skinning_offset;
};

layout(set = 6, binding = 0) readonly buffer MeshBuffer {
    MeshData meshes[];
};

struct VertexSkinningData {
    uvec4 joints;
    vec4 weights;
};

layout(set = 7, binding = 0) readonly buffer VertexSkinningBuffer {
    VertexSkinningData vertex_skinning[];
};

// Push constant budget: 64 bytes
layout(push_constant) uniform PushConstants {
    uint node_id;
    uint camera_index;
};


void main() {
    // Get camera from bindless buffer
    Camera camera = camera_buffer.cameras[camera_index];
    mat4 world = world_matrices[node_id];
    NodeData node = nodes[node_id];
    MeshData mesh = meshes[node.mesh_id];

    // Calculate position based on skinning
    vec4 modelPosition;
    if (mesh.is_skinned != 0u && node.bone_matrix_offset < boneMatrices.matrices.length()) {
        uint baseOffset = node.bone_matrix_offset;
        uint vertex_index = mesh.vertex_skinning_offset + gl_VertexIndex;
        VertexSkinningData skin = vertex_skinning[vertex_index];
        mat4 skinMatrix =
            skin.weights.x * boneMatrices.matrices[baseOffset + skin.joints.x] +
            skin.weights.y * boneMatrices.matrices[baseOffset + skin.joints.y] +
            skin.weights.z * boneMatrices.matrices[baseOffset + skin.joints.z] +
            skin.weights.w * boneMatrices.matrices[baseOffset + skin.joints.w];

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
