#version 450

layout(constant_id = 0) const bool SKINNED = false;

layout(location = 0) in vec3 inPosition;
layout(location = 4) in uvec4 inJoints;
layout(location = 5) in vec4 inWeights;

layout(set = 0, binding = 0) uniform Uniforms {
    mat4 view;
    mat4 proj;
    float time;
};

layout(set = 1, binding = 0) readonly buffer BoneMatrices {
    mat4 bones[];
};

layout(push_constant) uniform Constants {
    mat4 world;
};

void main() {
    vec4 modelPosition;
    if (SKINNED && false) {
        mat4 skinMatrix =
            inWeights.x * bones[inJoints.x] +
            inWeights.y * bones[inJoints.y] +
            inWeights.z * bones[inJoints.z] +
            inWeights.w * bones[inJoints.w];
        modelPosition = skinMatrix * vec4(inPosition, 1.0);
    } else {
        modelPosition = vec4(inPosition, 1.0);
    }
    vec4 worldPosition = world * modelPosition;
    gl_Position = proj * view * worldPosition;
}
