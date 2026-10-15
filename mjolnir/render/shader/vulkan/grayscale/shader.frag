#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform PostProcessPushConstant {
    float camera_near;
    float camera_far;
    uint normal_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    vec3 weights; // zero = Rec. 601 luma
    float strength;
};

void main() {
    vec4 color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    vec3 w = all(equal(weights, vec3(0.0))) ? vec3(0.299, 0.587, 0.114) : weights;
    float gray = dot(color.rgb, w);
    out_color = mix(color, vec4(gray, gray, gray, color.a), strength);
}
