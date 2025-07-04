#version 450
layout(constant_id = 0) const bool SKINNED = false;

// Vertex input attributes - same as uber shader
layout(location = 0) in vec3 inPosition;
layout(location = 5) in uvec4 inJoints;
layout(location = 6) in vec4 inWeights;

layout(set = 0, binding = 0) uniform SceneUniform {
    mat4 view;
    mat4 projection;
};

layout(set = 1, binding = 0) readonly buffer BoneBuffer {
    mat4 bone_matrices[];
};

// Push constants for world matrix
layout(push_constant) uniform PushConstant {
    mat4 world;
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
};

void main() {
    vec4 modelPos;
    if (SKINNED) {
        uvec4 indices = inJoints + uvec4(bone_matrix_offset);
        mat4 skinMatrix =
            inWeights.x * bone_matrices[indices.x] +
            inWeights.y * bone_matrices[indices.y] +
            inWeights.z * bone_matrices[indices.z] +
            inWeights.w * bone_matrices[indices.w];
        modelPos = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPos = vec4(inPosition, 1.0);
    }
    vec4 worldPos = world * modelPos;
    gl_Position = projection * view * worldPos;
}
