#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec4 inColor;
layout(location = 3) in vec2 inUV;

layout(set = 0, binding = 0) uniform Uniforms {
    mat4 view;
    mat4 proj;
    float time;
};

layout(push_constant) uniform Constants {
    mat4 world;
};

layout(location = 0) out vec3 outNormal;
layout(location = 1) out vec4 outColor;
layout(location = 2) out vec2 outUV;
layout(location = 3) out vec3 outPosition;

void main() {
    outNormal = mat3(world) * inNormal;
    outColor = inColor;
    outUV = inUV;
    vec4 worldPosition = world * vec4(inPosition, 1.0);
    outPosition = worldPosition.xyz;
    gl_Position = proj * view * worldPosition;
}
