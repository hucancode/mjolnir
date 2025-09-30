#version 450

layout(location = 0) in vec2 inPosition;
layout(location = 1) in vec2 inUV;
layout(location = 2) in vec4 inColor;

layout(location = 0) out vec2 fragUV;
layout(location = 1) out vec4 fragColor;

layout(set = 0, binding = 0) uniform ProjectionBuffer {
    mat4 projection;
};

void main() {
    gl_Position = projection * vec4(inPosition, 0.0, 1.0);
    fragUV = inUV;
    fragColor = inColor;
}