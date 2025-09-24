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

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9]; // Align to 192-byte
};

// Bindless camera buffer (set 0, binding 0)
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

// Push constant budget: 64 bytes
layout(push_constant) uniform PushConstants {
    uint node_id;            // 4
    uint bone_matrix_offset; // 4
    uint material_id;        // 4
    uint mesh_id;            // 4
    uint camera_index;       // 4
};

void main() {
    Camera camera = camera_buffer.cameras[camera_index];
    mat4 world = world_matrices[node_id];
    MeshData mesh = meshes[mesh_id];
    // Calculate position based on skinning
    vec4 modelPosition;
    vec3 modelNormal;
    vec4 modelTangent;
    if (mesh.is_skinned != 0u) {
        uint vertex_index = mesh.vertex_skinning_offset + gl_VertexIndex;
        VertexSkinningData skin = vertex_skinning[vertex_index];
        uint baseOffset = bone_matrix_offset;
        mat4 skinMatrix =
            skin.weights.x * boneMatrices.matrices[baseOffset + skin.joints.x] +
            skin.weights.y * boneMatrices.matrices[baseOffset + skin.joints.y] +
            skin.weights.z * boneMatrices.matrices[baseOffset + skin.joints.z] +
            skin.weights.w * boneMatrices.matrices[baseOffset + skin.joints.w];

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
    // Calculate final position
    gl_Position = camera.projection * camera.view * worldPos;
}
