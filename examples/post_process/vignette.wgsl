// A user post-process shader: darkens toward `color` away from the screen center. Follows
// common.wgsl and postprocess.wgsl (render.post_shader_create).

struct Effect {
    color: vec3f,
    radius: f32,
    softness: f32,
    strength: f32,
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let scene = textureSample(input_texture, linear_clamp, in.uv);
    let d = length(in.uv - 0.5);
    let vignette = 1.0 - smoothstep(u.effect.radius - u.effect.softness, u.effect.radius, d);
    return vec4f(mix(u.effect.color, scene.rgb, mix(1.0, vignette, u.effect.strength)), 1.0);
}
