#version 450
#extension GL_EXT_nonuniform_qualifier : require

// camera set = 0
layout(set = 0, binding = 0) uniform SceneUniforms {
    mat4 view;
    mat4 proj;
};
// textures set = 1
layout (set = 1, binding = 0) uniform texture2D textures[];
layout (set = 1, binding = 1) uniform sampler samplers[];

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
