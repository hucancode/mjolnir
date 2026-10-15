// BlurEffect: separable blur, pass 0 horizontal, pass 1 vertical.

struct Effect {
    radius: f32,
    // 0.0 = box blur, 1.0 = gaussian blur
    weight_falloff: f32,
}

const MAX_RADIUS: f32 = 16.0;

fn gaussian_weight(distance: f32, sigma: f32) -> f32 {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let texel_size = 1.0 / vec2f(textureDimensions(input_texture));
    var color = vec4f(0.0);
    var total_weight = 0.0;
    let blur_radius = clamp(u.effect.radius, 1.0, MAX_RADIUS);
    let sigma = blur_radius * 0.3;
    let direction = select(vec2f(0.0, 1.0), vec2f(1.0, 0.0), u.pass_index == 0u);
    // step by 0.5 for smoother results
    for (var i = -blur_radius; i <= blur_radius; i += 0.5) {
        let offset = direction * i * texel_size;
        // weight_falloff blends a box (0) into a Gaussian (1)
        let weight = mix(1.0, gaussian_weight(i, sigma), u.effect.weight_falloff);
        color += textureSampleLevel(input_texture, linear_clamp, in.uv + offset, 0.0) * weight;
        total_weight += weight;
    }
    return color / total_weight;
}
