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

layout(push_constant) uniform PostProcessPushConstant {
    float camera_near;
    float camera_far;
    uint normal_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    vec3 fog_color;
    float fog_start;
    float fog_end;
};

// Distance along the view axis from a [0, 1] perspective depth value.
float linearize_depth(float depth) {
    return camera_near * camera_far / (camera_far - depth * (camera_far - camera_near));
}

float compute_fog_factor(float distance) {
    if (distance >= fog_end) {
        return 1.0;
    }
    if (distance <= fog_start) {
        return 0.0;
    }
    return clamp((distance - fog_start) / (fog_end - fog_start), 0.0, 1.0);
}

void main() {
    vec4 color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    float depth = texture(sampler2D(textures[depth_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), v_uv).r;
    float linear_depth = linearize_depth(depth);
    float fog_factor = compute_fog_factor(linear_depth);
    vec3 final_color = mix(color.rgb, fog_color, fog_factor);
    out_color = vec4(final_color, 1);
}
