// Diffuse irradiance: the environment cube integrated over each texel's hemisphere, one
// sample per `value` radians of each angle.

@group(3) @binding(0) var source: texture_cube<f32>;

@compute @workgroup_size(8, 8)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    var n: vec3f;
    if (!texel_dir(gid, &n)) { return; }
    var up = select(vec3f(0.0, 0.0, 1.0), vec3f(0.0, 1.0, 0.0), abs(n.y) < 0.999);
    let right = normalize(cross(up, n));
    up = normalize(cross(n, right));
    var irradiance = vec3f(0.0);
    var count = 0.0;
    let delta = max(u.value, 0.005);
    for (var phi = 0.0; phi < 2.0 * PI; phi += delta) {
        for (var theta = 0.0; theta < 0.5 * PI; theta += delta) {
            let s = sin(theta);
            let tangent = vec3f(s * cos(phi), s * sin(phi), cos(theta));
            let world = tangent.x * right + tangent.y * up + tangent.z * n;
            irradiance += textureSampleLevel(source, linear_repeat, world, 0.0).rgb * cos(theta) * s;
            count += 1.0;
        }
    }
    irradiance = PI * irradiance / count;
    textureStore(destination, gid.xy, gid.z, vec4f(irradiance, 1.0));
}
