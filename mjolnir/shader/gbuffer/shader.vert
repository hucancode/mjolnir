#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;
layout(location = 4) in vec4 inTangent;

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
// set 1 (textures), not available in vertex shader
layout(set = 2, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
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

layout(push_constant) uniform PushConstants {
    uint node_id;
    uint camera_index;
};

layout(location = 0) out vec3 outPosition;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec3 outNormal;
layout(location = 3) out vec2 outUV;
layout(location = 4) out vec4 outTangent;

void main() {
    Camera camera = cameras[camera_index];
    mat4 world = world_matrices[node_id];
    NodeData node = nodes[node_id];
    MeshData mesh = meshes[node.mesh_id];

    vec4 modelPosition;
    vec3 modelNormal;
    vec4 modelTangent;
    if (mesh.is_skinned != 0u && node.bone_matrix_offset != 0xFFFFFFFFu) {
        uint vertex_index = mesh.vertex_skinning_offset + gl_VertexIndex;
        VertexSkinningData skin = vertex_skinning[vertex_index];
        uvec4 indices = skin.joints + uvec4(node.bone_matrix_offset);
        mat4 skinMatrix =
            skin.weights.x * bones[indices.x] +
            skin.weights.y * bones[indices.y] +
            skin.weights.z * bones[indices.z] +
            skin.weights.w * bones[indices.w];
        modelPosition = skinMatrix * vec4(inPosition, 1.0);
        modelNormal = mat3(skinMatrix) * inNormal;
        modelTangent = skinMatrix * inTangent;
    } else {
        modelPosition = vec4(inPosition, 1.0);
        modelNormal = inNormal;
        modelTangent = inTangent;
    }
    vec4 worldPosition = world * modelPosition;
    outNormal = normalize(mat3(world) * modelNormal);
    outTangent = normalize(world * modelTangent);
    outUV = inUV;
    outColor = inColor;
    outPosition = worldPosition.xyz;
    gl_Position = camera.projection * camera.view * worldPosition;
}
