#version 450

layout(constant_id = 0) const bool SKINNED = false;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;
layout(location = 4) in vec4 inTangent;
layout(location = 5) in uvec4 inJoints;
layout(location = 6) in vec4 inWeights;

struct CameraUniform {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9]; // Align to 192-byte
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    CameraUniform cameras[];
};
// set 1 (textures), not available in vertex shader
layout(set = 2, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

layout(push_constant) uniform PushConstants {
    mat4 world;
    uint bone_matrix_offset;
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint camera_index;
};

layout(location = 0) out vec3 outPosition;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec3 outNormal;
layout(location = 3) out vec2 outUV;
layout(location = 4) out vec4 outTangent;

void main() {
    CameraUniform camera = cameras[camera_index];

    vec4 modelPosition;
    vec3 modelNormal;
    vec4 modelTangent;
    if (SKINNED) {
        uvec4 indices = inJoints + uvec4(bone_matrix_offset);
        mat4 skinMatrix =
            inWeights.x * bones[indices.x] +
            inWeights.y * bones[indices.y] +
            inWeights.z * bones[indices.z] +
            inWeights.w * bones[indices.w];
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
