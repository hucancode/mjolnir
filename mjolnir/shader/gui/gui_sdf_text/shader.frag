#version 450

layout(binding = 0, set = 1) uniform sampler2D fontAtlas;

layout(location = 0) in vec4 color;
layout(location = 1) in vec2 uv;

layout(location = 0) out vec4 outColor;

void main() {
    float distance = texture(fontAtlas, uv).r;
    float smoothWidth = fwidth(distance);
    float alpha = smoothstep(0.5 - smoothWidth, 0.5 + smoothWidth, distance);
    outColor = vec4(color.rgb, color.a * alpha);
}