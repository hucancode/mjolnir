// Paints the snake: overlapping scales, a zigzag down the back, a pale belly and two eyes, in
// toon bands of the sun with a rim light.

fn eye(t: f32, up: f32, side: f32, len: f32) -> f32 {
    let across = acos(clamp(dot(normalize(vec2f(abs(side), up)), vec2f(0.8, 0.6)), -1.0, 1.0));
    return length(vec2f((t - 0.055) * len, across * 0.5));
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let m = node_material(in);
    let view = views[u.camera_index];
    let up = in.color.x;
    let t = in.color.y;
    let len = unpack2x16float(bitcast<u32>(m.params[0].z)).x;
    let n = normalize(in.normal);

    var cell = vec2f(in.uv.x * 28.0, t * 90.0);
    cell.x += 0.5 * (floor(cell.y) % 2.0);
    var skin = m.base_color_factor.rgb * (1.0 - 0.3 * smoothstep(0.3, 0.5, length(fract(cell) - 0.5)));
    let zig = abs(fract(t * 14.0) - 0.5) * 0.6;
    skin = mix(skin, vec3f(0.98, 0.78, 0.2), step(0.85 - zig, up) * step(0.12, t));
    skin = mix(skin, vec3f(1.0, 0.93, 0.65), smoothstep(-0.2, -0.5, up));

    let light = floor(max(dot(n, view.sun_direction.xyz), 0.0) * 3.0 + 0.5) / 3.0;
    var color = skin * view.sun_radiance.rgb * mix(0.45, 1.0, light);
    let rim = 1.0 - max(dot(n, normalize(view.position.xyz - in.position)), 0.0);
    color += 0.2 * step(0.7, rim);

    let d = eye(t, up, in.color.z, len);
    color = mix(color, vec3f(1.0), step(d, 0.11));
    color = mix(color, vec3f(0.02), step(eye(t + 0.006, up, in.color.z, len), 0.055));
    return vec4f(color, 1.0);
}
