#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(binding = 0, set = 1) uniform texture2D textures[];
layout(binding = 1, set = 1) uniform sampler samplers[];

layout(push_constant) uniform PushConstants {
    mat4 projection;
    uint texture_id;
};

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;

layout(location = 0) in vec4 color;
layout(location = 1) in vec2 uv;

layout(location = 0) out vec4 outColor;

void main() {
    // Glyph atlases are white RGBA with coverage in alpha, so one multiply
    // serves glyphs, solid quads (white texture) and images.
    outColor = color * texture(sampler2D(textures[texture_id], samplers[SAMPLER_NEAREST_CLAMP]), uv);
}
