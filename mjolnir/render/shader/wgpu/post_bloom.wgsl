// BloomEffect: pass 0 bright-passes and blurs horizontally, pass 1 blurs vertically and
// composites over the original (the image as it entered pass 0).

struct Effect {
    threshold: f32,
    intensity: f32,
    blur_radius: f32,
}

const MAX_RADIUS: f32 = 64.0;

fn luminance(color: vec3f) -> f32 {
    return dot(color, vec3f(0.2126, 0.7152, 0.0722));
}

fn gaussian_weight(distance: f32, sigma: f32) -> f32 {
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

// UE4/Karis soft-knee bright-pass: a smooth transition around threshold avoids the hard
// cutoff that creates ringing and amplitude cliffs.
fn soft_brightpass(c: vec3f, lum: f32, threshold: f32) -> vec3f {
    let knee = threshold * 0.5;
    var soft = clamp(lum - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    let contribution = max(soft, lum - threshold) / max(lum, 1e-4);
    return c * contribution;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let texel_size = 1.0 / vec2f(textureDimensions(input_texture));
    let radius = clamp(u.effect.blur_radius, 1.0, MAX_RADIUS);
    // 3-sigma rule: the kernel decays to ~0 by the loop edge, so the truncated separable
    // Gaussian leaves no square halo
    let sigma = radius / 3.0;
    let is_horizontal = u.pass_index == 0u;
    let dir = select(vec2f(0.0, 1.0), vec2f(1.0, 0.0), is_horizontal);
    var acc = vec3f(0.0);
    var total = 0.0;
    for (var i = -radius; i <= radius; i += 1.0) {
        var c = textureSampleLevel(input_texture, linear_clamp, in.uv + dir * i * texel_size, 0.0).rgb;
        if (is_horizontal) {
            c = soft_brightpass(c, luminance(c), u.effect.threshold);
        }
        let w = gaussian_weight(i, sigma);
        acc += c * w;
        total += w;
    }
    let blurred = acc / total;
    let original = textureSampleLevel(original_texture, linear_clamp, in.uv, 0.0).rgb;
    if (is_horizontal) {
        return vec4f(blurred, 1.0);
    }
    // soft additive: the blur attenuates where the original is already bright, so raising
    // intensity doesn't run away into saturation
    let boost = blurred * u.effect.intensity;
    return vec4f(original + boost / (1.0 + 0.25 * boost), 1.0);
}
