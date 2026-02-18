#version 450

layout(location = 0) in vec3 inPosition;

layout(location = 0) out vec3 worldPos;
layout(location = 1) out uint instanceIndex;

struct ShadowData {
    mat4 view;
    mat4 projection;
    vec3 position;
    float near;
    vec3 direction;
    float far;
    vec4 frustum_planes[6];
};

layout(set = 0, binding = 0) readonly buffer ShadowBuffer {
    ShadowData shadows[];
};

layout(set = 2, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

layout(set = 4, binding = 0) readonly buffer WorldMatrices {
    mat4 world_matrices[];
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

layout(push_constant) uniform PushConstants {
    uint shadow_index;
};

void main() {
    uint node_index = uint(gl_InstanceIndex);
    mat4 world = world_matrices[node_index];
    NodeData node = nodes[node_index];
    MeshData mesh = meshes[node.mesh_id];
    vec4 modelPosition;

    // Handle skeletal animation
    bool is_skinned = (mesh.flags & MESH_FLAG_SKINNED) != 0u &&
                      node.attachment_data_index < bones.length();
    if (is_skinned) {
        int local_index = gl_VertexIndex - mesh.vertex_offset;
        uint vertex_index = mesh.vertex_skinning_offset + uint(local_index);
        VertexSkinningData skin = vertex_skinning[vertex_index];
        uvec4 indices = skin.joints + uvec4(node.attachment_data_index);
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
    instanceIndex = node_index;

    // Don't transform to clip space yet - geometry shader will handle projection for each cube face
    gl_Position = worldPosition;
}
