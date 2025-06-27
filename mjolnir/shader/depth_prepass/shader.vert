#version 450

// Vertex input attributes - same as uber shader
layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec4 inTangent;
layout(location = 4) in uvec4 inJoints;
layout(location = 5) in vec4 inWeights;

// Descriptor sets
layout(set = 0, binding = 0) uniform SceneUniform {
    mat4 view;
    mat4 projection;
    float time;
    float padding[3];
} scene;

layout(set = 3, binding = 0) readonly buffer BoneBuffer {
    mat4 bone_matrices[];
};

// Push constants for world matrix
layout(push_constant) uniform PushConstant {
    mat4 world;
    // Other material properties from PushConstant struct (not used in depth pre-pass)
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint displacement_index;
    uint emissive_index;
    uint environment_index;
    uint brdf_lut_index;
    uint bone_matrix_offset;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    float padding;
} push;

// Specialization constants for features
layout(constant_id = 0) const bool IS_SKINNED = false;

void main() {
    vec4 modelPos;

    if (IS_SKINNED) {
        // Apply skinning transformation with bone matrix offset (same method as uber shader)
        uvec4 indices = inJoints + uvec4(push.bone_matrix_offset);
        mat4 skinMatrix =
            inWeights.x * bone_matrices[indices.x] +
            inWeights.y * bone_matrices[indices.y] +
            inWeights.z * bone_matrices[indices.z] +
            inWeights.w * bone_matrices[indices.w];

        modelPos = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPos = vec4(inPosition, 1.0);
    }

    // Apply world transform, then view-projection (same order as main shader)
    vec4 worldPos = push.world * modelPos;
    gl_Position = scene.projection * scene.view * worldPos;
}
