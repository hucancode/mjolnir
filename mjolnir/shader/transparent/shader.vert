#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const bool SKINNED = false;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inTangent;
layout(location = 3) in vec2 inTexCoord;
layout(location = 4) in vec4 inColor;
layout(location = 5) in uvec4 inJointIndices;
layout(location = 6) in vec4 inJointWeights;

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

// Push constant budget: 128 bytes
layout(push_constant) uniform PushConstants {
    mat4 world;            // 64 bytes
    uint bone_matrix_offset; // 4
    uint albedo_index;     // 4
    uint metallic_roughness_index; // 4
    uint normal_index;     // 4
    uint emissive_index;   // 4
    float metallic_value;  // 4
    float roughness_value; // 4
    float emissive_value;  // 4
    uint camera_index;     // 4
    float padding[3];        // 12 (pad to 128)
};

void main() {
    Camera camera = camera_buffer.cameras[camera_index];
    // Calculate position based on skinning
    vec4 modelPosition;
    vec3 modelNormal;
    vec4 modelTangent;
    if (SKINNED) {
        uint baseOffset = bone_matrix_offset;
        mat4 skinMatrix =
            inJointWeights.x * boneMatrices.matrices[baseOffset + inJointIndices.x] +
            inJointWeights.y * boneMatrices.matrices[baseOffset + inJointIndices.y] +
            inJointWeights.z * boneMatrices.matrices[baseOffset + inJointIndices.z] +
            inJointWeights.w * boneMatrices.matrices[baseOffset + inJointIndices.w];

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
