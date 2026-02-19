#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inTangent;
layout(location = 3) in vec2 inTexCoord;
layout(location = 4) in vec4 inColor;

layout(location = 0) flat out uint outNodeIndex;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    vec4 frustum_planes[6];
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
};

layout(set = 2, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

struct NodeData {
    mat4 world_matrix;
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
};

layout(set = 4, binding = 0) readonly buffer NodeBuffer {
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

layout(push_constant) uniform PushConstants {
    uint camera_index;
};

void main() {
    Camera camera = cameras[camera_index];
    uint node_index = uint(gl_InstanceIndex);
    mat4 world = nodes[node_index].world_matrix;
    NodeData node = nodes[node_index];
    MeshData mesh = meshes[node.mesh_id];

    vec4 modelPosition;
    bool is_skinned = (mesh.flags & MESH_FLAG_SKINNED) != 0u &&
                      node.attachment_data_index < bones.length();
    if (is_skinned) {
        uint baseOffset = node.attachment_data_index;
        int local_index = gl_VertexIndex - mesh.vertex_offset;
        uint vertex_index = mesh.vertex_skinning_offset + uint(local_index);
        VertexSkinningData skin = vertex_skinning[vertex_index];
        mat4 skinMatrix =
            skin.weights.x * bones[baseOffset + skin.joints.x] +
            skin.weights.y * bones[baseOffset + skin.joints.y] +
            skin.weights.z * bones[baseOffset + skin.joints.z] +
            skin.weights.w * bones[baseOffset + skin.joints.w];
        modelPosition = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPosition = vec4(inPosition, 1.0);
    }

    vec4 worldPos = world * modelPosition;
    gl_Position = camera.projection * camera.view * worldPos;
    outNodeIndex = node_index;
}
