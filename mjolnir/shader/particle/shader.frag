#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout (set = 0, binding = 0) uniform texture2D textures[];
layout (set = 1, binding = 0) uniform sampler samplers[];

layout(push_constant) uniform PushConstants {
    mat4 view;
    mat4 proj;
    float time;
    uint texture_index;
};

layout (location = 0) in vec4 inColor;
layout (location = 0) out vec4 outFragColor;

void main() {
    // Sample the particle texture using point coordinates
    vec4 texColor = texture(sampler2D(textures[nonuniformEXT(texture_index)], samplers[3]), gl_PointCoord);
    // Combine texture color with the interpolated particle color and fade by life ratio
    outFragColor = vec4(inColor.rgb, texColor.a*inColor.a);
}
