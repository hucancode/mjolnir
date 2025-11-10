#version 450
#extension GL_EXT_nonuniform_qualifier : enable

layout(binding = 0, set = 1) uniform texture2D textures[];
layout(binding = 1, set = 1) uniform sampler samplers[];

layout(constant_id = 4) const uint SAMPLER_LINEAR_CLAMP = 1u;

layout(location = 0) in vec4 color;
layout(location = 1) in vec2 uv;
layout(location = 2) flat in uint textureId;
layout(location = 0) out vec4 outColor;

void main() {
    vec4 texColor = texture(sampler2D(textures[textureId], samplers[SAMPLER_LINEAR_CLAMP]), uv);
    outColor = color * texColor;
}
