#version 450

layout(constant_id = 0) const bool SKINNED = false;

layout(location = 0) in vec3 inPosition;
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

layout(set = 1, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

// TODO: recheck this push constant
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

void main() {
    CameraUniform camera = cameras[camera_index];
    vec4 modelPosition;
    if (SKINNED) {
        uvec4 indices = inJoints + uvec4(bone_matrix_offset);
        mat4 skinMatrix =
            inWeights.x * bones[indices.x] +
            inWeights.y * bones[indices.y] +
            inWeights.z * bones[indices.z] +
            inWeights.w * bones[indices.w];
        modelPosition = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPosition = vec4(inPosition, 1.0);
    }
    vec4 worldPosition = world * modelPosition;
    gl_Position = camera.projection * camera.view * worldPosition;
}
