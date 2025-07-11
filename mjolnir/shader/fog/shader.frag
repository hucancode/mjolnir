#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform texture2D textures[];
layout(set = 0, binding = 1) uniform sampler samplers[];
layout(set = 0, binding = 2) uniform textureCube textures_cube[];

layout(push_constant) uniform PostProcessPushConstant {
    uint gbuffer_position_index;
    uint gbuffer_normal_index;
    uint gbuffer_albedo_index;
    uint gbuffer_metallic_index;
    uint gbuffer_emissive_index;
    uint gbuffer_depth_index;
    uint input_image_index;
    uint padding; // Add padding to match Odin struct
    vec4 fog_color;
    float fog_density;
    float fog_start;
    float fog_end;
};

// Camera parameters - these should match camera setup
// TODO: move those to uniform buffer
const float near_plane = 0.1;
const float far_plane = 50.0;

float linearize_depth(float depth) {
    float z = depth * 2.0 - 1.0; // Back to NDC
    return (2.0 * near_plane * far_plane) / (far_plane + near_plane - z * (far_plane - near_plane));
}

float compute_fog_factor(float distance) {
    if (distance >= fog_end) {
        return 1.0;
    }
    if (distance <= fog_start) {
        return 0.0;
    }
    // Linear fog
    float factor = (distance - fog_start) / (fog_end - fog_start);
    // Exponential fog (alternative)
    // float factor = 1.0 - exp(-fog_density * distance);
    // Exponential squared fog (alternative)
    // float factor = 1.0 - exp(-fog_density * fog_density * distance * distance);
    return clamp(factor, 0.0, 1.0);
}

void main() {
    vec4 color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    vec4 normal = texture(sampler2D(textures[gbuffer_normal_index], samplers[SAMPLER_NEAREST_CLAMP]), v_uv);
    float depth = texture(sampler2D(textures[gbuffer_depth_index], samplers[SAMPLER_NEAREST_CLAMP]), v_uv).r;
    float linear_depth = linearize_depth(depth);
    float fog_factor = compute_fog_factor(linear_depth);
    vec3 final_color = mix(color.rgb, fog_color.rgb, fog_factor);
    out_color = vec4(final_color, 1);
}
