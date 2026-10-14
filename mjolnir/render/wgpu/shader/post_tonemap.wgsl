// ToneMapEffect: exposure tonemap. The sRGB view of the presented image encodes; gamma is
// kept as additional curve shaping (1.0 = off).

struct Effect {
    exposure: f32,
    gamma: f32,
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    var color = textureSample(input_texture, linear_clamp, in.uv).rgb;
    color = vec3f(1.0) - exp(-color * u.effect.exposure);
    let gamma = u.effect.gamma;
    if (gamma > 0.0 && abs(gamma - 1.0) > 1e-4) {
        color = pow(color, vec3f(1.0 / gamma));
    }
    return vec4f(color, 1.0);
}
