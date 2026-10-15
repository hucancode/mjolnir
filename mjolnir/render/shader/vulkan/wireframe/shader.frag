#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;
layout(location = 2) in vec3 inNormal;
layout(location = 3) in vec2 inUV;
layout(location = 4) in vec4 inTangent;
layout(location = 5) flat in uint inNodeIndex;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(inColor.rgb, 1);
}
