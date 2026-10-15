// No effect: copies the input.

struct Effect {
    _unused: u32,
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return textureSample(input_texture, linear_clamp, in.uv);
}
