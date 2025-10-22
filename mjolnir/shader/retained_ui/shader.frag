#version 450
#extension GL_EXT_nonuniform_qualifier : enable

layout(binding = 0, set = 1) uniform sampler2D textures[];

layout(location = 0) in vec4 color;
layout(location = 1) in vec2 uv;
layout(location = 2) flat in uint textureId;
layout(location = 0) out vec4 outColor;

void main() {
    vec4 texColor = texture(textures[textureId], uv);
    outColor = color * texColor;
}
