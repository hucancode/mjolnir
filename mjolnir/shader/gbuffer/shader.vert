#version 450

layout(constant_id = 0) const bool SKINNED = false;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;
layout(location = 4) in vec4 inTangent;
layout(location = 5) in uvec4 inJoints;
layout(location = 6) in vec4 inWeights;

layout(set = 0, binding = 0) uniform Uniforms {
    mat4 view;
    mat4 proj;
};
// set 1 (light uniforms), not available in vertex shader
// set 2 (textures), not available in vertex shader
// layout(set = 2, binding = 0) uniform texture2D textures[];
// layout(set = 2, binding = 0) uniform sampler samplers[];
layout(set = 3, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

layout(push_constant) uniform PushConstants {
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

layout(location = 0) out vec3 outPosition;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec3 outNormal;
layout(location = 3) out vec2 outUV;

void main() {
    vec4 modelPosition;
    vec3 modelNormal;
    if (SKINNED) {
        uvec4 indices = inJoints + uvec4(bone_matrix_offset);
        mat4 skinMatrix =
            inWeights.x * bones[indices.x] +
            inWeights.y * bones[indices.y] +
            inWeights.z * bones[indices.z] +
            inWeights.w * bones[indices.w];
        modelPosition = skinMatrix * vec4(inPosition, 1.0);
        modelNormal = mat3(skinMatrix) * inNormal;
    } else {
        modelPosition = vec4(inPosition, 1.0);
        modelNormal = inNormal;
    }
    vec4 worldPosition = world * modelPosition;
    outNormal = normalize(mat3(world) * modelNormal);
    outUV = inUV;
    outColor = inColor;
    outPosition = worldPosition.xyz;
    gl_Position = proj * view * worldPosition;
}
