// The environment cube from the equirect map.

@group(3) @binding(0) var source: texture_2d<f32>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    var dir: vec3f;
    if (!texel_dir(gid, &dir)) { return; }
    let color = textureSampleLevel(source, linear_repeat, dir_to_equirect_uv(dir), 0.0).rgb;
    textureStore(destination, gid.xy, gid.z, vec4f(color, 1.0));
}
