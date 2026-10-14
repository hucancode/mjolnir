// DoFEffect: bokeh blur of pixels away from the focus plane.

struct Effect {
    // distance to the focus plane
    focus_distance: f32,
    // range where objects are in focus
    focus_range: f32,
    // maximum blur radius
    blur_strength: f32,
    bokeh_intensity: f32,
}

const MAX_BLUR_RADIUS: f32 = 16.0;

// Distance along the view axis from a [0, 1] perspective depth value.
fn linearize_depth(depth: f32) -> f32 {
    return u.camera_near * u.camera_far / (u.camera_far - depth * (u.camera_far - u.camera_near));
}

fn blur_amount(linear_depth: f32) -> f32 {
    let distance_from_focus = abs(linear_depth - u.effect.focus_distance);
    if (distance_from_focus <= u.effect.focus_range) {
        return 0.0;
    }
    let blur_factor = (distance_from_focus - u.effect.focus_range) / (u.effect.focus_distance * 0.5);
    return clamp(blur_factor * u.effect.blur_strength, 0.0, MAX_BLUR_RADIUS);
}

fn gaussian_weight(distance: f32, sigma: f32) -> f32 {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

// Circular sampling pattern, bright samples weighted up for the bokeh look.
fn bokeh_blur(uv: vec2f, blur_radius: f32) -> vec4f {
    let texel_size = 1.0 / vec2f(textureDimensions(input_texture));
    var color = vec4f(0.0);
    var total_weight = 0.0;
    let sigma = blur_radius * 0.3;
    let samples = i32(clamp(blur_radius, 1.0, 8.0)) * 2;
    for (var i = 0; i < samples; i++) {
        for (var j = 0; j < samples; j++) {
            let offset = vec2f(f32(i) - f32(samples) * 0.5, f32(j) - f32(samples) * 0.5);
            let distance = length(offset);
            let sample_uv = uv + offset * texel_size;
            if (distance <= blur_radius && all(sample_uv >= vec2f(0.0)) && all(sample_uv <= vec2f(1.0))) {
                let sample_color = textureSampleLevel(input_texture, linear_clamp, sample_uv, 0.0);
                var weight = gaussian_weight(distance, sigma);
                let luminance = dot(sample_color.rgb, vec3f(0.2126, 0.7152, 0.0722));
                weight *= 1.0 + luminance * u.effect.bokeh_intensity;
                color += sample_color * weight;
                total_weight += weight;
            }
        }
    }
    // the center sample always lands, so total_weight > 0
    return color / total_weight;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let original = textureSample(input_texture, linear_clamp, in.uv);
    let blur_radius = blur_amount(linearize_depth(depth_at(in.uv)));
    // in focus: sharp
    if (blur_radius < 0.5) {
        return original;
    }
    return bokeh_blur(in.uv, blur_radius);
}
