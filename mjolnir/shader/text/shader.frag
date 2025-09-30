#version 450

layout(location = 0) in vec2 fragUV;
layout(location = 1) in vec4 fragColor;

layout(location = 0) out vec4 outColor;

layout(set = 1, binding = 0) uniform sampler2D fontAtlas;

void main() {
    float alpha = texture(fontAtlas, fragUV).r;
    outColor = vec4(fragColor.rgb, fragColor.a * alpha);
}