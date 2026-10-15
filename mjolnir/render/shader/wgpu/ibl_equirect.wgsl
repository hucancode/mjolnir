// The environment cube from the equirect map.

@group(3) @binding(0) var source: texture_2d<f32>;

fn dir_to_equirect_uv(dir: vec3f) -> vec2f {
    let u = atan2(dir.z, dir.x) / (2.0 * PI) + 0.5;
    let v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
    return vec2f(u, v);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    var dir: vec3f;
    if (!texel_dir(gid, &dir)) { return; }
    let color = textureSampleLevel(source, linear_repeat, dir_to_equirect_uv(dir), 0.0).rgb;
    textureStore(destination, gid.xy, gid.z, vec4f(color, 1.0));
}
