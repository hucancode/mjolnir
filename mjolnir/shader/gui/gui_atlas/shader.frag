#version 450

layout(binding = 0, set = 1) uniform sampler2D guiAtlas;

layout(location = 0) in vec4 color;
layout(location = 1) in vec2 uv;

layout(location = 0) out vec4 outColor;

void main() {
    vec4 texColor = texture(guiAtlas, uv);
    outColor = texColor * color;
}