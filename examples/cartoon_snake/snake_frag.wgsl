// Paints the snake: rows of overlapping scales, each lying over the front of the ones behind it
// and shading them, a zigzag down the back and speckles picked scale by scale, plated belly and
// the mouth, in toon bands of the sun with glossy glints and a rim light. Reads
// (up, along, around, mouth) from the vertex shader, around a fraction of a turn from the top.

const AROUND: f32 = 22.0;
const ROWS: f32 = 7.5;
const SCALE: f32 = 0.72;

fn hash(p: vec2f) -> f32 {
    return fract(sin(dot(p, vec2f(127.1, 311.7))) * 43758.5453);
}

// The scale in row k nearest g, every other row shifted half a scale.
fn scale_center(g: vec2f, k: f32) -> vec2f {
    let shift = 0.5 * (k - 2.0 * floor(k / 2.0));
    return vec2f(floor(g.x - shift) + 0.5 + shift, k + 0.5);
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let m = node_material(in);
    let view = views[u.camera_index];
    let up = in.color.x;
    let along = in.color.y;
    let n = normalize(in.normal);

    let g = vec2f(in.color.z * AROUND, along * ROWS);
    var c = scale_center(g, floor(g.y) + 1.0);
    for (var k = 0; k >= -1; k--) {
        let o = scale_center(g, floor(g.y) + f32(k));
        c = select(c, o, distance(g, o) < SCALE);
    }
    let d = distance(g, c) / SCALE;
    let front = distance(g, scale_center(g, c.y - 1.5)) / SCALE;

    let at = c / vec2f(AROUND, ROWS);
    let wave = (abs(fract(at.y * 1.6) - 0.5) - 0.25) * 0.2;
    let stripe = abs(at.x - wave) * AROUND * step(0.5, at.y);
    let speck = hash(c);
    var skin = m.base_color_factor.rgb * (0.85 + 0.3 * hash(c + 17.0));
    skin = mix(skin, vec3f(0.08, 0.12, 0.05), step(speck, 0.06));
    skin = mix(skin, vec3f(0.1, 0.15, 0.06), step(stripe, 2.0) * step(0.5, at.y));
    skin = mix(skin, vec3f(0.98, 0.78, 0.2), step(stripe, 1.0) * step(0.5, at.y));

    let rim = smoothstep(0.8 - fwidth(d), 0.95, d);
    let shadow = 1.0 - smoothstep(1.0, 1.3, front);
    skin *= (1.1 - 0.25 * d) * (1.0 - 0.4 * rim) * (1.0 - 0.35 * shadow);

    let belly = vec3f(1.0, 0.93, 0.65) * (1.0 - 0.3 * smoothstep(0.7, 0.95, fract(along * 5.0)));
    skin = mix(skin, belly, 1.0 - smoothstep(-0.5, -0.2, up));

    let sun = view.sun_direction.xyz;
    let eye = normalize(view.position.xyz - in.position);
    let light = floor(max(dot(n, sun), 0.0) * 3.0 + 0.5) / 3.0;
    var color = skin * view.sun_radiance.rgb * mix(0.45, 1.0, light);
    let gloss = step(0.97, dot(n, normalize(sun + eye))) * (1.0 - d) * (1.0 - d);
    color += 0.4 * gloss * view.sun_radiance.rgb;
    color += 0.2 * step(0.7, 1.0 - max(dot(n, eye), 0.0));
    color = mix(color, vec3f(0.55, 0.1, 0.15), step(0.5, in.color.w));
    return vec4f(color, 1.0);
}
