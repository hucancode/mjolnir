#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform PostPush {
    float camera_near;
    float camera_far;
    uint normal_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    float exposure;
    float gamma;
};

void main() {
    vec3 color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv).rgb;
    // Exposure tonemap. sRGB swapchain handles linear->sRGB encoding; gamma
    // param kept for back-compat as additional curve shaping (1.0 = off).
    color = vec3(1.0) - exp(-color * exposure);
    if (gamma > 0.0 && abs(gamma - 1.0) > 1e-4) {
        color = pow(color, vec3(1.0 / gamma));
    }
    out_color = vec4(color, 1.0);
}
