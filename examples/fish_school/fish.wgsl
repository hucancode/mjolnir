// Builds each fish from the vertex index: a body of SEGMENTS rings of SIDES vertices from nose
// to tail fin, bent side to side by its swim phase and turned along its velocity. Paints it: a
// hue of its own, dark stripes across the back, a silver belly, lit by the sun with caustics
// rippling over the top.

struct Params {
    first: u32,
}

struct Fish {
    position: vec3f,
    phase: f32,
    velocity: vec3f,
    size: f32,
}

@group(1) @binding(0) var<storage, read> fish: array<Fish>;

struct VertexOut {
    @builtin(position) clip: vec4f,
    @location(0) position: vec3f,
    @location(1) normal: vec3f,
    @location(2) body: vec2f,
    @location(3) @interpolate(flat) fish: u32,
}

const SEGMENTS: u32 = 16u;
const SIDES: u32 = 10u;
const CORNERS = array<vec2f, 6>(vec2f(0, 0), vec2f(1, 0), vec2f(1, 1), vec2f(0, 0), vec2f(1, 1), vec2f(0, 1));

// t runs from the nose (0) to the tail (1), a around the body.
fn body(t: f32, a: f32, phase: f32) -> vec3f {
    var height: f32;
    var width: f32;
    if (t < 0.8) {
        let s = pow(sin(PI * t / 0.8), 0.7);
        height = 0.42 * s;
        width = 0.2 * s;
    } else {
        height = 0.55 * (t - 0.8) / 0.2;
        width = 0.03;
    }
    var p = vec3f(cos(a) * width, sin(a) * height, 0.5 - t);
    p.x += sin(t * 5.0 - phase) * 0.18 * t * t;
    return p;
}

@vertex
fn vs_main(@builtin(vertex_index) vertex: u32, @builtin(instance_index) instance: u32) -> VertexOut {
    let quad = vertex / 6u;
    let corner = CORNERS[vertex % 6u];
    let t = (f32(quad / SIDES) + corner.x) / f32(SEGMENTS);
    let a = (f32(quad % SIDES) + corner.y) / f32(SIDES) * 2.0 * PI;
    let f = fish[gpu.params.first + instance];

    let p = body(t, a, f.phase);
    var n = normalize(cross(body(t + 0.01, a, f.phase) - p, body(t, a + 0.01, f.phase) - p));
    if (dot(n, vec3f(cos(a), sin(a), 0.0)) < 0.0) {
        n = -n;
    }

    let forward = normalize(f.velocity + vec3f(0.0, 0.0, 1e-4));
    let right = normalize(cross(vec3f(0.0, 1.0, 0.0), forward) + vec3f(1e-4, 0.0, 0.0));
    let turn = mat3x3f(right, cross(forward, right), forward);
    var out: VertexOut;
    out.position = f.position + turn * p * f.size * 2.0;
    out.normal = turn * n;
    out.body = vec2f(t, sin(a));
    out.fish = instance;
    out.clip = clip_output(views[gpu.camera_index].view_projection * vec4f(out.position, 1.0));
    return out;
}

fn hue(h: f32) -> vec3f {
    return clamp(abs(fract(h + vec3f(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, vec3f(0.0), vec3f(1.0));
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let view = views[gpu.camera_index];
    let n = normalize(in.normal);
    let h = fract(f32(in.fish) * 0.618034);
    var color = mix(hue(h), vec3f(1.0, 0.7, 0.3), 0.35);
    color *= mix(1.0, 0.35, step(0.55, fract(in.body.x * 6.0)) * step(0.0, in.body.y));
    color = mix(color, vec3f(0.85, 0.88, 0.92), smoothstep(-0.1, -0.5, in.body.y));
    let sun = max(dot(n, view.sun_direction.xyz), 0.0);
    let ripple = 0.5 + 0.5 * sin(in.position.x * 2.3 + view.time * 1.7) * sin(in.position.z * 2.1 - view.time * 1.3);
    let lit = color * (view.sun_radiance.rgb * sun + 0.25) + pow(ripple, 4.0) * 0.5 * max(n.y, 0.0);
    return vec4f(lit, 1.0);
}
