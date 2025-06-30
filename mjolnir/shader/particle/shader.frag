#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout (set = 0, binding = 0) uniform texture2D textures[];
layout (set = 0, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform PushConstants {
    mat4 view;
    mat4 proj;
    float time;
    uint texture_index;
};

layout (location = 0) in vec4 inColor;
layout (location = 1) in flat uint inTextureIndex;
layout (location = 0) out vec4 outFragColor;

void main() {
    vec4 texColor = texture(sampler2D(textures[nonuniformEXT(inTextureIndex)], samplers[3]), gl_PointCoord);
    vec4 finalColor = vec4(inColor.rgb, texColor.a * inColor.a);
    if (finalColor.a < 0.01) {
        discard;
    }
    outFragColor = finalColor;
}
