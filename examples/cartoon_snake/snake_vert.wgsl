// Carves a snake out of a sphere as long as it: the sphere's rings run head to tail along the
// spine, which retraces the path the head travelled and slithers with the distance travelled. Reads
//   params[0]  x the distance travelled, y the speed, z the length and radius (two halves)
//   params[0].w, params[1]  how far the body turns over each of its stretches, 3 bytes a float
// and hands the fragment shader (up, along, side) of the body in color.

const WAVES: f32 = 2.0;

fn girth(t: f32, radius: f32) -> f32 {
    let head = 1.0 + 0.4 * exp(-pow((t - 0.06) / 0.05, 2.0));
    return radius * head * pow(sin(PI * t), 0.35) * (1.0 - 0.6 * t);
}

const SAMPLES: i32 = 15;
const TURN_SCALE: f32 = 0.5 * 6.0 / 15.0 / 127.0; // radians per byte: MAX_CURVATURE * len / SAMPLES / 127

// The direction the body runs `s` down it, as the angle it has turned from the head's: the head's
// heading minus the one it had then. It turns steadily over each of the SAMPLES stretches.
fn turned(k: ptr<function, array<f32, 15>>, s: f32, len: f32) -> f32 {
    let f = clamp(s / len, 0.0, 1.0) * f32(SAMPLES);
    let i = min(i32(f), SAMPLES - 1);
    var angle = 0.0;
    for (var j = 0; j < i; j++) {
        angle += (*k)[j];
    }
    return (angle + (*k)[i] * (f - f32(i))) * TURN_SCALE;
}

// The point `s` down the body, the head at -len / 2: the path the head travelled. Also gives the
// direction the body runs there.
fn spine(k: ptr<function, array<f32, 15>>, s: f32, len: f32, along: ptr<function, vec3f>) -> vec3f {
    let steps = 32;
    let h = s / f32(steps);
    var p = vec2f(0.0);
    for (var i = 0; i < steps; i++) {
        let angle = turned(k, (f32(i) + 0.5) * h, len);
        p += h * vec2f(-sin(angle), cos(angle));
    }
    let angle = turned(k, s, len);
    *along = vec3f(-sin(angle), 0.0, cos(angle));
    return vec3f(p.x, 0.0, p.y - 0.5 * len);
}

// How far the body swings aside at `t`: waves running down it as it travels, wider at speed.
fn sway(t: f32, motion: vec4f) -> f32 {
    let amplitude = 0.4 * smoothstep(0.0, 0.3, t) * mix(0.15, 1.0, clamp(motion.y / 3.0, 0.0, 1.0));
    return sin(t * WAVES * 2.0 * PI - motion.x * 2.5) * amplitude;
}

@vertex
fn vs_main(in: VertexIn) -> VertexOut {
    let m = vertex_material(in);
    let motion = m.params[0];
    let size = unpack2x16float(bitcast<u32>(motion.z));
    let len = size.x;
    let radius = size.y;
    let packed = array<f32, 5>(motion.w, m.params[1].x, m.params[1].y, m.params[1].z, m.params[1].w);
    var k: array<f32, 15>;
    for (var i = 0; i < SAMPLES; i++) {
        let b = i32((bitcast<u32>(packed[i / 3]) >> u32(8 * (i % 3))) & 255u);
        k[i] = f32(select(b, b - 256, b > 127));
    }
    let t = clamp(in.uv.y, 0.001, 0.999);
    let around = normalize(in.position.xz + vec2f(1e-5, 0.0));

    var forward: vec3f;
    let center = spine(&k, t * len, len, &forward);
    let side = normalize(vec3f(forward.z, 0.0, -forward.x));
    let normal = normalize(side * around.x + vec3f(0.0, around.y, 0.0));
    let r = girth(t, radius);
    var position = center + side * (sway(t, motion) + around.x * r);
    position.y = r * 0.65 + around.y * r * select(1.0, 0.65, around.y < 0.0);

    var out = material_vertex(in, position, normal);
    out.color = vec4f(around.y, t, around.x, 1.0);
    return out;
}
