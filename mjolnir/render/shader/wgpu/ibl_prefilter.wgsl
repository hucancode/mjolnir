// Specular prefilter of one mip: GGX importance samples of the environment cube at roughness
// `value`, weighted by n·l.

@group(3) @binding(0) var source: texture_cube<f32>;

fn radical_inverse_vdc(b: u32) -> f32 {
    var bits = (b << 16u) | (b >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return f32(bits) * 2.3283064365386963e-10;
}

fn hammersley(i: u32, n: u32) -> vec2f {
    return vec2f(f32(i) / f32(n), radical_inverse_vdc(i));
}

fn importance_sample_ggx(xi: vec2f, n: vec3f, a: f32) -> vec3f {
    let phi = 2.0 * PI * xi.x;
    let cos_theta = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
    let sin_theta = sqrt(1.0 - cos_theta * cos_theta);
    let h = vec3f(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
    let up = select(vec3f(0.0, 0.0, 1.0), vec3f(0.0, 1.0, 0.0), abs(n.y) < 0.999);
    let tx = normalize(cross(up, n));
    let ty = cross(n, tx);
    return normalize(tx * h.x + ty * h.y + n * h.z);
}

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    var n: vec3f;
    if (!texel_dir(gid, &n)) { return; }
    let v = n;
    let a = max(u.value * u.value, 1e-4);
    var color = vec3f(0.0);
    var weight = 0.0;
    for (var i = 0u; i < u.sample_count; i++) {
        let h = importance_sample_ggx(hammersley(i, u.sample_count), n, a);
        let l = normalize(2.0 * dot(v, h) * h - v);
        let n_dot_l = max(dot(n, l), 0.0);
        if (n_dot_l <= 0.0) { continue; }
        color += textureSampleLevel(source, linear_repeat, l, 0.0).rgb * n_dot_l;
        weight += n_dot_l;
    }
    color /= max(weight, 1e-4);
    textureStore(destination, gid.xy, gid.z, vec4f(color, 1.0));
}
