#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;
layout(set = 0, binding = 1) uniform sampler2D u_depth_texture;

layout(push_constant) uniform FogData {
    vec3 fog_color;
    float fog_density;
    float fog_start;
    float fog_end;
    vec2 padding;
} fog;

// Camera parameters - these should match your camera setup
const float near_plane = 0.1;
const float far_plane = 1000.0;

float linearize_depth(float depth) {
    float z = depth * 2.0 - 1.0; // Back to NDC
    return (2.0 * near_plane * far_plane) / (far_plane + near_plane - z * (far_plane - near_plane));
}

float compute_fog_factor(float distance) {
    if (distance >= fog.fog_end) {
        return 1.0;
    }
    if (distance <= fog.fog_start) {
        return 0.0;
    }

    // Linear fog
    float factor = (distance - fog.fog_start) / (fog.fog_end - fog.fog_start);

    // Exponential fog (alternative)
    // float factor = 1.0 - exp(-fog.fog_density * distance);

    // Exponential squared fog (alternative)
    // float factor = 1.0 - exp(-fog.fog_density * fog.fog_density * distance * distance);

    return clamp(factor, 0.0, 1.0);
}

void main() {
    vec4 color = texture(u_input_image, v_uv);
    float depth = texture(u_depth_texture, v_uv).r;

    // Convert depth to linear distance
    float linear_depth = linearize_depth(depth);

    // Calculate fog factor
    float fog_factor = compute_fog_factor(linear_depth);

    // Apply fog
    vec3 final_color = mix(color.rgb, fog.fog_color, fog_factor);

    out_color = vec4(final_color, color.a);
}
