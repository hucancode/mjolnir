#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inTangent;
layout(location = 3) in vec2 inTexCoord;
layout(location = 4) in vec4 inColor;

// Output to fragment shader
layout(location = 0) out vec3 outWorldPos;
layout(location = 1) out vec3 outNormal;
layout(location = 2) out vec2 outTexCoord;
layout(location = 3) out vec4 outColor;
layout(location = 4) out mat3 outTBN;
layout(location = 7) flat out uint outNodeIndex;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    vec4 frustum_planes[6];
};

// Bindless camera buffer (set 0, binding 0)
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
};
// Bone matrices
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

// Push constant budget: 64 bytes
layout(push_constant) uniform PushConstants {
    uint camera_index;
};

void main() {
    Camera camera = cameras[camera_index];
    uint node_index = uint(gl_InstanceIndex);
    mat4 world = nodes[node_index].world_matrix;
    NodeData node = nodes[node_index];
    MeshData mesh = meshes[node.mesh_id];
    // Calculate position based on skinning
    vec4 modelPosition;
    vec3 modelNormal;
    vec4 modelTangent;
    bool is_skinned = (mesh.flags & MESH_FLAG_SKINNED) != 0u &&
                      node.attachment_data_index < bones.length();
    if (is_skinned) {
        int local_index = gl_VertexIndex - mesh.vertex_offset;
        uint vertex_index = mesh.vertex_skinning_offset + uint(local_index);
        VertexSkinningData skin = vertex_skinning[vertex_index];
        uint baseOffset = node.attachment_data_index;
        mat4 skinMatrix =
            skin.weights.x * bones[baseOffset + skin.joints.x] +
            skin.weights.y * bones[baseOffset + skin.joints.y] +
            skin.weights.z * bones[baseOffset + skin.joints.z] +
            skin.weights.w * bones[baseOffset + skin.joints.w];

        modelPosition = skinMatrix * vec4(inPosition, 1.0);
        modelNormal = mat3(skinMatrix) * inNormal;
        modelTangent = skinMatrix * inTangent;
    } else {
        modelPosition = vec4(inPosition, 1.0);
        modelNormal = inNormal;
        modelTangent = inTangent;
    }
    vec4 worldPos = world * modelPosition;
    // Output to fragment shader
    outWorldPos = worldPos.xyz;
    outNormal = mat3(world) * modelNormal;
    outTexCoord = inTexCoord;
    outColor = inColor;
    // Calculate tangent-bitangent-normal matrix for normal mapping
    vec3 N = normalize(outNormal).xyz;
    vec3 T = normalize(world * modelTangent).xyz;
    // Re-orthogonalize T with respect to N
    T = normalize(T - dot(T, N) * N);
    vec3 B = normalize(cross(N, T)) * modelTangent.w;
    outTBN = mat3(T, B, N);
    outNodeIndex = node_index;
    // Calculate final position
    gl_Position = camera.projection * camera.view * worldPos;
}
