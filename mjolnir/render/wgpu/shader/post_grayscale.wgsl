// GrayscaleEffect: desaturates toward luma by strength.

struct Effect {
    // zero = Rec. 601 luma
    weights: vec3f,
    strength: f32,
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let color = textureSample(input_texture, linear_clamp, in.uv);
    let w = select(u.effect.weights, vec3f(0.299, 0.587, 0.114), all(u.effect.weights == vec3f(0.0)));
    let gray = dot(color.rgb, w);
    return mix(color, vec4f(gray, gray, gray, color.a), u.effect.strength);
}
