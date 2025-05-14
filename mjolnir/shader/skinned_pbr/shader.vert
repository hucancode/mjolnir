#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;
layout(location = 4) in uvec4 inJoints;
layout(location = 5) in vec4 inWeights;

layout(set = 0, binding = 0) uniform Uniforms {
    mat4 view;
    mat4 proj;
    float time;
};

layout(set = 1, binding = 3) buffer BoneMatrices {
    mat4 bones[];
};

layout(push_constant) uniform Constants {
    mat4 world;
};

layout(location = 0) out vec3 outNormal;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec2 outUV;
layout(location = 3) out vec3 outPosition;

void main() {
    mat4 skinMatrix =
        inWeights.x * bones[inJoints.x] +
        inWeights.y * bones[inJoints.y] +
        inWeights.z * bones[inJoints.z] +
        inWeights.w * bones[inJoints.w];
    vec4 skinnedPosition = skinMatrix * vec4(inPosition, 1.0);
    //vec4 unskinnedPosition = vec4(inPosition, 1.0);
    vec3 skinnedNormal = mat3(skinMatrix) * inNormal;
    outNormal = normalize(mat3(world) * skinnedNormal);
    outColor = inJoints * 0.25;
    outUV = inUV;
    vec4 worldPosition = world * skinnedPosition;
    outPosition = worldPosition.xyz;
    gl_Position = proj * view * worldPosition;
}
