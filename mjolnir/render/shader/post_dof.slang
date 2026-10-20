// DoFEffect: bokeh blur of pixels away from the focus plane.
struct Effect {
    // distance to the focus plane
    float focus_distance;
    // range where objects are in focus
    float focus_range;
    // maximum blur radius
    float blur_strength;
    float bokeh_intensity;
}
#include "post.slang"

static const float MAX_BLUR_RADIUS = 16.0;

float blur_amount(float linear_depth)
{
    Effect e = effect();
    float distance_from_focus = abs(linear_depth - e.focus_distance);
    if (distance_from_focus <= e.focus_range) {
        return 0.0;
    }
    float blur_factor = (distance_from_focus - e.focus_range) / (e.focus_distance * 0.5);
    return clamp(blur_factor * e.blur_strength, 0.0, MAX_BLUR_RADIUS);
}

// Circular sampling pattern, bright samples weighted up for the bokeh look.
float4 bokeh_blur(float2 uv, float blur_radius)
{
    float2 texel_size = 1.0 / post_resolution();
    float4 color = float4(0.0);
    float total_weight = 0.0;
    float sigma = blur_radius * 0.3;
    int samples = int(clamp(blur_radius, 1.0, 8.0)) * 2;
    for (int i = 0; i < samples; i++) {
        for (int j = 0; j < samples; j++) {
            float2 offset = float2(float(i) - float(samples) * 0.5, float(j) - float(samples) * 0.5);
            float distance = length(offset);
            float2 sample_uv = uv + offset * texel_size;
            if (distance <= blur_radius && all(sample_uv >= float2(0.0)) && all(sample_uv <= float2(1.0))) {
                float4 sample_color = post_input_level(sample_uv);
                float weight = gaussian_weight(distance, sigma);
                float luminance = dot(sample_color.rgb, float3(0.2126, 0.7152, 0.0722));
                weight *= 1.0 + luminance * effect().bokeh_intensity;
                color += sample_color * weight;
                total_weight += weight;
            }
        }
    }
    // the center sample always lands, so total_weight > 0
    return color / total_weight;
}

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    float4 original = post_input(v.uv);
    float blur_radius = blur_amount(linearize_depth(post_depth(v.uv)));
    // in focus: sharp
    if (blur_radius < 0.5) {
        return original;
    }
    return bokeh_blur(v.uv, blur_radius);
}
