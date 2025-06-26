#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;
layout(set = 0, binding = 2) uniform sampler2D u_depth_texture;

layout(push_constant) uniform DoFParams {
    float focus_distance;    // Distance to the focus plane
    float focus_range;       // Range where objects are in focus
    float blur_strength;     // Maximum blur radius
    float bokeh_intensity;   // Bokeh effect intensity
} dof;

// Camera parameters - these should match your camera setup
const float near_plane = 0.1;
const float far_plane = 1000.0;
const float MAX_BLUR_RADIUS = 16.0;

float linearize_depth(float depth) {
    float z = depth * 2.0 - 1.0; // Back to NDC
    return (2.0 * near_plane * far_plane) / (far_plane + near_plane - z * (far_plane - near_plane));
}

float compute_blur_amount(float linear_depth) {
    // Calculate distance from focus plane
    float distance_from_focus = abs(linear_depth - dof.focus_distance);

    // Objects within focus range are sharp
    if (distance_from_focus <= dof.focus_range) {
        return 0.0;
    }

    // Objects outside focus range get blurred
    float blur_factor = (distance_from_focus - dof.focus_range) / (dof.focus_distance * 0.5);
    return clamp(blur_factor * dof.blur_strength, 0.0, MAX_BLUR_RADIUS);
}

// Optimized Gaussian weight calculation
float gaussian_weight(float distance, float sigma) {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

// Bokeh blur - creates circular blur pattern
vec4 bokeh_blur(vec2 uv, float blur_radius) {
    vec2 texel_size = 1.0 / vec2(textureSize(u_input_image, 0));
    vec4 color = vec4(0.0);
    float total_weight = 0.0;

    float sigma = blur_radius * 0.3;
    int samples = int(clamp(blur_radius, 1.0, 8.0)) * 2; // Adaptive sample count

    // Circular sampling pattern for bokeh effect
    for (int i = 0; i < samples; i++) {
        for (int j = 0; j < samples; j++) {
            vec2 offset = vec2(float(i) - float(samples) * 0.5, float(j) - float(samples) * 0.5);
            float distance = length(offset);

            // Only sample within circular area
            if (distance <= blur_radius) {
                vec2 sample_uv = uv + offset * texel_size;

                // Check bounds
                if (sample_uv.x >= 0.0 && sample_uv.x <= 1.0 && sample_uv.y >= 0.0 && sample_uv.y <= 1.0) {
                    vec4 sample_color = texture(u_input_image, sample_uv);

                    // Gaussian weight for smooth falloff
                    float weight = gaussian_weight(distance, sigma);

                    // Enhance bright areas for bokeh effect
                    float luminance = dot(sample_color.rgb, vec3(0.2126, 0.7152, 0.0722));
                    weight *= 1.0 + luminance * dof.bokeh_intensity;

                    color += sample_color * weight;
                    total_weight += weight;
                }
            }
        }
    }

    return total_weight > 0.0 ? color / total_weight : texture(u_input_image, uv);
}

// Fast separable Gaussian blur for performance
vec4 gaussian_blur(vec2 uv, float blur_radius, bool horizontal) {
    vec2 texel_size = 1.0 / vec2(textureSize(u_input_image, 0));
    vec4 color = vec4(0.0);
    float total_weight = 0.0;

    float sigma = blur_radius * 0.3;
    vec2 direction = horizontal ? vec2(1.0, 0.0) : vec2(0.0, 1.0);

    // Use fewer samples for performance
    for (float i = -blur_radius; i <= blur_radius; i += 1.0) {
        vec2 offset = direction * i * texel_size;
        vec4 sample_color = texture(u_input_image, uv + offset);
        float weight = gaussian_weight(abs(i), sigma);

        color += sample_color * weight;
        total_weight += weight;
    }

    return color / total_weight;
}

void main() {
    vec4 original_color = texture(u_input_image, v_uv);
    float depth = texture(u_depth_texture, v_uv).r;

    // Convert depth to linear distance
    float linear_depth = linearize_depth(depth);

    // Calculate blur amount based on depth
    float blur_radius = compute_blur_amount(linear_depth);

    vec4 final_color;

    if (blur_radius < 0.5) {
        // Sharp - no blur needed
        final_color = original_color;
    } else if (blur_radius < 4.0) {
        // Light blur - use fast Gaussian
        final_color = gaussian_blur(v_uv, blur_radius, true); // Could do separable passes
    } else {
        // Heavy blur - use bokeh effect
        final_color = bokeh_blur(v_uv, blur_radius);
    }

    out_color = final_color;
}
