#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

layout(push_constant) uniform PushConstants {
    mat4 mvp_matrix;
} pc;

void main() {
    gl_Position = pc.mvp_matrix * vec4(inPosition, 1.0);
    outColor = inColor;
}