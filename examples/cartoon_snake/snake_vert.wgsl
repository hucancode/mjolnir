// Wraps a sphere around the path the head slithered: its rings run neck to tail along a spline
// through the neck (the node) and the spine points behind it, the body pinching on the inside of
// a bend and leaning into it. Reads
//   params  the spine points, an (x, z) pair of halves each, evenly spaced down the body
// and hands the fragment shader (up, along, around, 0) of the body in color, around a fraction
// of a turn from the top.

const POINTS: i32 = 9;
const RADIUS: f32 = 0.45;

fn girth(t: f32) -> f32 {
    return RADIUS * mix(0.7, 1.0, smoothstep(0.0, 0.2, t)) * pow(1.0 - t, 0.7);
}

// Spine point i, the ends carried on straight.
fn spine_point(p: ptr<function, array<vec2f, 9>>, i: i32) -> vec2f {
    if (i < 0) {
        return 2.0 * (*p)[0] - (*p)[1];
    }
    if (i >= POINTS) {
        return 2.0 * (*p)[POINTS - 1] - (*p)[POINTS - 2];
    }
    return (*p)[i];
}

@vertex
fn vs_main(in: VertexIn) -> VertexOut {
    let m = vertex_material(in);
    var p: array<vec2f, 9>;
    for (var i = 1; i < POINTS; i++) {
        p[i] = unpack2x16float(bitcast<u32>(m.params[(i - 1) / 4][(i - 1) % 4]));
    }
    var len = 0.0;
    for (var i = 1; i < POINTS; i++) {
        len += distance(p[i - 1], p[i]);
    }

    // a Catmull-Rom spline through the points, with its first two derivatives
    let t = clamp(in.uv.y, 0.001, 0.999);
    let u = t * f32(POINTS - 1);
    let i = min(i32(u), POINTS - 2);
    let f = u - f32(i);
    let a = spine_point(&p, i - 1);
    let b = p[i];
    let c = p[i + 1];
    let d = spine_point(&p, i + 2);
    let c1 = c - a;
    let c2 = 2.0 * a - 5.0 * b + 4.0 * c - d;
    let c3 = -a + 3.0 * b - 3.0 * c + d;
    let center = b + 0.5 * (c1 * f + c2 * f * f + c3 * f * f * f);
    let d1 = 0.5 * (c1 + 2.0 * c2 * f + 3.0 * c3 * f * f);
    let d2 = 0.5 * (2.0 * c2 + 6.0 * c3 * f);
    let along = normalize(d1);
    let side = vec3f(along.y, 0.0, -along.x);
    // how hard the body bends toward `side`, in body widths
    let bend = clamp(-RADIUS * (d1.x * d2.y - d1.y * d2.x) / pow(length(d1), 3.0), -0.8, 0.8);

    let around = normalize(in.position.xz + vec2f(1e-5, 0.0));
    let inner = bend * around.x;
    let scale = vec2f(1.0 - 0.35 * inner, select(1.0 + 0.3 * max(inner, 0.0), 0.65, around.y < 0.0));
    let r = girth(t);
    let roll = 0.25 * bend;
    let lean = mat2x2f(cos(roll), -sin(roll), sin(roll), cos(roll));
    let offset = lean * (around * scale * r);
    let facing = lean * normalize(around / scale);

    let position = vec3f(center.x, r * 0.65, center.y) + side * offset.x + vec3f(0.0, offset.y, 0.0);
    let normal = side * facing.x + vec3f(0.0, facing.y, 0.0);
    var out = material_vertex(in, position, normal);
    out.color = vec4f(around.y, t * len, atan2(around.x, around.y) / 6.2831853, 0.0);
    return out;
}
