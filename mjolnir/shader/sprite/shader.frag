#version 450
#extension GL_EXT_nonuniform_qualifier : require
layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint MAX_SAMPLERS = 1u;
layout(constant_id = 3) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 4) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 5) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 6) const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;
layout(location = 2) in vec2 inUV;
layout(location = 3) flat in uint inTextureIndex;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(location = 0) out vec4 outColor;

void main() {
    vec4 tex_color = texture(sampler2D(textures[inTextureIndex], samplers[SAMPLER_NEAREST_CLAMP]), inUV);
    outColor = tex_color * inColor;
    outColor = tex_color;
}
