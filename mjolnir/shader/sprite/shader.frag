#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;
layout(location = 2) in vec2 inUV;
layout(location = 3) flat in uint inNodeIndex;
layout(location = 4) flat in uint inSpriteIndex;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

struct SpriteData {
    uint texture_index;
    uint sampler_index;
    uint frame_columns;
    uint frame_rows;
    uint frame_index;
    uint _padding[3];
    vec4 color;
};

layout(set = 4, binding = 0) readonly buffer SpriteBuffer {
    SpriteData sprites[];
};

layout(location = 0) out vec4 outColor;

void main() {
    SpriteData sprite = sprites[inSpriteIndex];

    // Sample texture using sprite's texture and sampler indices
    vec4 tex_color = texture(
        sampler2D(textures[sprite.texture_index], samplers[sprite.sampler_index]),
        inUV
    );

    // Apply color modulation with full alpha blending
    outColor = tex_color * sprite.color * inColor;
}
