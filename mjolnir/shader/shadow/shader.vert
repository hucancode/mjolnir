#version 450

layout(location = 0) in vec3 inPosition;

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

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
};

layout(set = 2, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

layout(set = 4, binding = 0) readonly buffer WorldMatrices {
    mat4 world_matrices[];
};

struct MeshData {
    vec3 aabb_min;
    uint is_skinned;
    vec3 aabb_max;
    uint vertex_skinning_offset;
};

layout(set = 5, binding = 0) readonly buffer MeshBuffer {
    MeshData meshes[];
};

struct VertexSkinningData {
    uvec4 joints;
    vec4 weights;
};

layout(set = 6, binding = 0) readonly buffer VertexSkinningBuffer {
    VertexSkinningData vertex_skinning[];
};

// TODO: recheck this push constant
layout(push_constant) uniform PushConstants {
    uint node_id;
    uint bone_matrix_offset;
    uint material_id;
    uint mesh_id;
    uint camera_index;
};

void main() {
    Camera camera = cameras[camera_index];
    mat4 world = world_matrices[node_id];
    MeshData mesh = meshes[mesh_id];
    vec4 modelPosition;
    if (mesh.is_skinned != 0u) {
        uint vertex_index = mesh.vertex_skinning_offset + gl_VertexIndex;
        VertexSkinningData skin = vertex_skinning[vertex_index];
        uvec4 indices = skin.joints + uvec4(bone_matrix_offset);
        mat4 skinMatrix =
            skin.weights.x * bones[indices.x] +
            skin.weights.y * bones[indices.y] +
            skin.weights.z * bones[indices.z] +
            skin.weights.w * bones[indices.w];
        modelPosition = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPosition = vec4(inPosition, 1.0);
    }
    vec4 worldPosition = world * modelPosition;
    worldPos = worldPosition.xyz;
    gl_Position = camera.projection * camera.view * worldPosition;
}
