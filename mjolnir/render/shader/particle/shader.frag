#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

// Camera structure
struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    mat4 inv_view_projection;
};

// Bindless camera buffer set = 0
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

// textures set = 1
layout (set = 1, binding = 0) uniform texture2D textures[];
layout (set = 1, binding = 1) uniform sampler samplers[];

layout (location = 0) in vec4 inColor;
layout (location = 1) in flat uint inTextureIndex;
layout (location = 0) out vec4 outFragColor;

void main() {
    vec4 texColor = texture(sampler2D(textures[nonuniformEXT(inTextureIndex)], samplers[SAMPLER_LINEAR_REPEAT]), gl_PointCoord);
    vec4 finalColor = vec4(inColor.rgb, texColor.a * inColor.a);
    if (finalColor.a < 0.01) {
        discard;
    }
    outFragColor = finalColor;
}
