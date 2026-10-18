#version 450
#extension GL_EXT_nonuniform_qualifier : require
const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;
layout(location = 2) in vec2 inUV;
layout(location = 3) flat in uint inTextureIndex;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(location = 0) out vec4 outColor;

void main() {
    vec4 tex_color = texture(sampler2D(textures[nonuniformEXT(inTextureIndex)], samplers[SAMPLER_NEAREST_CLAMP]), inUV);
    outColor = tex_color * inColor;
    // reconsider this if we want to support semi-transparent sprite
    if (outColor.a < 0.5) discard;
}
