#version 450

layout(constant_id = 0) const bool SKINNED = false;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inTangent;
layout(location = 3) in vec2 inTexCoord;
layout(location = 4) in vec4 inColor;
layout(location = 5) in uvec4 inJointIndices;
layout(location = 6) in vec4 inJointWeights;

// Output to fragment shader
layout(location = 0) out vec4 outColor;

// Uniform buffer - camera data
layout(set = 0, binding = 0) uniform CameraUniform {
    mat4 view;
    mat4 projection;
    vec2 viewportSize;
} camera;

// Bone matrices
layout(set = 3, binding = 0) readonly buffer BoneMatrices {
    mat4 matrices[];
} boneMatrices;

// Push constants
layout(push_constant) uniform PushConstants {
    mat4 world;            // 64 bytes
    uint bone_matrix_offset; // 4
};

void main() {
    // Calculate position based on skinning
    vec4 modelPosition;
    if (SKINNED) {
        uint baseOffset = bone_matrix_offset;
        mat4 skinMatrix =
            inJointWeights.x * boneMatrices.matrices[baseOffset + inJointIndices.x] +
            inJointWeights.y * boneMatrices.matrices[baseOffset + inJointIndices.y] +
            inJointWeights.z * boneMatrices.matrices[baseOffset + inJointIndices.z] +
            inJointWeights.w * boneMatrices.matrices[baseOffset + inJointIndices.w];

        modelPosition = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPosition = vec4(inPosition, 1.0);
    }
    // Transform to world space
    vec4 worldPos = world * modelPosition;
    // Pass color to fragment shader
    outColor = inColor;
    // Calculate final position
    gl_Position = camera.projection * camera.view * worldPos;
}
