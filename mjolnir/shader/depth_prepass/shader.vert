#version 450

layout(location = 0) in vec3 inPosition;

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

layout(set = 2, binding = 0) readonly buffer BoneBuffer {
    mat4 bone_matrices[];
};

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

// Push constants for world matrix
layout(push_constant) uniform PushConstant {
    uint camera_index;
};

void main() {
    Camera camera = cameras[camera_index];
    uint node_index = uint(gl_InstanceIndex);
    mat4 world = world_matrices[node_index];
    NodeData node = nodes[node_index];
    MeshData mesh = meshes[node.mesh_id];
    vec4 modelPos;
    if (mesh.is_skinned != 0u && node.bone_matrix_offset != 0xFFFFFFFFu) {
        uint vertex_index = mesh.vertex_skinning_offset + gl_VertexIndex;
        VertexSkinningData skin = vertex_skinning[vertex_index];
        uvec4 indices = skin.joints + uvec4(node.bone_matrix_offset);
        mat4 skinMatrix =
            skin.weights.x * bone_matrices[indices.x] +
            skin.weights.y * bone_matrices[indices.y] +
            skin.weights.z * bone_matrices[indices.z] +
            skin.weights.w * bone_matrices[indices.w];
        modelPos = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPos = vec4(inPosition, 1.0);
    }
    vec4 worldPos = world * modelPos;
    gl_Position = camera.projection * camera.view * worldPos;
}
