#version 450

layout(location = 0) in vec3 inNormal;
layout(location = 1) in vec3 inWorldPos;
layout(location = 2) in vec4 inDebugColor;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = inDebugColor;
}