#version 450
#extension GL_EXT_nonuniform_qualifier : enable

layout(binding = 0, set = 0) uniform texture2D textures[];
layout(binding = 1, set = 0) uniform sampler samplers[];

layout(constant_id = 1) const uint SAMPLER_LINEAR_CLAMP = 1u;

layout(location = 0) in vec4 color;
layout(location = 1) in vec2 uv;
layout(location = 2) flat in uint textureId;

layout(location = 0) out vec4 outColor;

void main() {
    // Sample texture - use red channel as alpha for R8 textures (font atlas)
    // For RGBA textures (colored quads), the red channel will be 1.0 for white
    float texAlpha = texture(sampler2D(textures[textureId], samplers[SAMPLER_LINEAR_CLAMP]), uv).r;
    outColor = vec4(color.rgb, color.a * texAlpha);
}
