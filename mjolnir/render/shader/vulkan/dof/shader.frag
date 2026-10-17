#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(push_constant) uniform PostPush {
    float camera_near;
    float camera_far;
    uint normal_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint _pad0;
    uint _pad1;
    uint _pad2;
    float focus_distance;    // Distance to the focus plane
    float focus_range;       // Range where objects are in focus
    float blur_strength;     // Maximum blur radius
    float bokeh_intensity;   // Bokeh effect intensity
};

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

const float MAX_BLUR_RADIUS = 16.0;

// Distance along the view axis from a [0, 1] perspective depth value.
float linearize_depth(float depth) {
    return camera_near * camera_far / (camera_far - depth * (camera_far - camera_near));
}

float compute_blur_amount(float linear_depth) {
    // Calculate distance from focus plane
    float distance_from_focus = abs(linear_depth - focus_distance);

    // Objects within focus range are sharp
    if (distance_from_focus <= focus_range) {
        return 0.0;
    }

    // Objects outside focus range get blurred
    float blur_factor = (distance_from_focus - focus_range) / (focus_distance * 0.5);
    return clamp(blur_factor * blur_strength, 0.0, MAX_BLUR_RADIUS);
}

// Optimized Gaussian weight calculation
float gaussian_weight(float distance, float sigma) {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

// Bokeh blur - creates circular blur pattern
vec4 bokeh_blur(vec2 uv, float blur_radius) {
    vec2 texel_size = 1.0 / vec2(textureSize(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), 0));
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
                    vec4 sample_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), sample_uv);

                    // Gaussian weight for smooth falloff
                    float weight = gaussian_weight(distance, sigma);

                    // Enhance bright areas for bokeh effect
                    float luminance = dot(sample_color.rgb, vec3(0.2126, 0.7152, 0.0722));
                    weight *= 1.0 + luminance * bokeh_intensity;

                    color += sample_color * weight;
                    total_weight += weight;
                }
            }
        }
    }

    // the center sample always lands, so total_weight > 0
    return color / total_weight;
}

void main() {
    vec4 original_color = texture(sampler2D(textures[input_image_index], samplers[SAMPLER_LINEAR_CLAMP]), v_uv);
    float depth = texture(sampler2D(textures[depth_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), v_uv).r;
    float linear_depth = linearize_depth(depth);
    // Calculate blur amount based on depth
    float blur_radius = compute_blur_amount(linear_depth);
    // in focus: sharp
    out_color = blur_radius < 0.5 ? original_color : bokeh_blur(v_uv, blur_radius);
}
