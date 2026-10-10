#version 450

layout(location = 0) in vec3 inPosition;

layout(push_constant) uniform PushConstants {
    mat4 view_projection;
};

layout(set = 1, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

struct NodeData {
    mat4 world_matrix;
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
};

layout(set = 3, binding = 0) readonly buffer NodeBuffer {
    NodeData nodes[];
};

const uint MESH_FLAG_SKINNED = 1u << 0;

struct MeshData {
    vec3 aabb_min;
    uint index_count;
    vec3 aabb_max;
    uint first_index;
    int vertex_offset;
    uint vertex_skinning_offset;
    uint flags;
    uint _padding;
};

layout(set = 4, binding = 0) readonly buffer MeshBuffer {
    MeshData meshes[];
};

struct VertexSkinningData {
    uvec4 joints;
    vec4 weights;
};

layout(set = 5, binding = 0) readonly buffer VertexSkinningBuffer {
    VertexSkinningData vertex_skinning[];
};

void main() {
    uint node_index = uint(gl_InstanceIndex);
    mat4 world = nodes[node_index].world_matrix;
    NodeData node = nodes[node_index];
    MeshData mesh = meshes[node.mesh_id];
    vec4 model_position;
    bool is_skinned = (mesh.flags & MESH_FLAG_SKINNED) != 0u &&
                      node.attachment_data_index < bones.length();
    if (is_skinned) {
        int local_index = gl_VertexIndex - mesh.vertex_offset;
        uint vertex_index = mesh.vertex_skinning_offset + uint(local_index);
        VertexSkinningData skin = vertex_skinning[vertex_index];
        uvec4 indices = skin.joints + uvec4(node.attachment_data_index);
        mat4 skin_matrix =
            skin.weights.x * bones[indices.x] +
            skin.weights.y * bones[indices.y] +
            skin.weights.z * bones[indices.z] +
            skin.weights.w * bones[indices.w];
        model_position = skin_matrix * vec4(inPosition, 1.0);
    } else {
        model_position = vec4(inPosition, 1.0);
    }
    vec4 world_position = world * model_position;
    gl_Position = view_projection * world_position;
}
