#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;
const uint NO_TEXTURE = 0xFFFFFFFFu;

// textures set = 1
layout (set = 1, binding = 0) uniform texture2D textures[];
layout (set = 1, binding = 1) uniform sampler samplers[];

layout (location = 0) in vec4 inColor;
layout (location = 1) in flat uint inTextureIndex;
layout (location = 0) out vec4 outFragColor;

void main() {
    float texAlpha = inTextureIndex == NO_TEXTURE ? 1.0 : texture(sampler2D(textures[nonuniformEXT(inTextureIndex)], samplers[SAMPLER_LINEAR_REPEAT]), gl_PointCoord).a;
    vec4 finalColor = vec4(inColor.rgb, texAlpha * inColor.a);
    if (finalColor.a < 0.01) {
        discard;
    }
    outFragColor = finalColor;
}
