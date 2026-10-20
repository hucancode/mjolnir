// A ring of fire around the sphere on a disc: three layers of procedural noise tiling around
// the disc, each its own size, scrolling around it and outward, multiplied together and by a
// gradient rising and falling across the disc's radius, eroded where that falls below a
// threshold, fading out across a range. The fire is colored in three tones by its alpha: tone 1
// where the alpha is highest, falling off sharply to tone 2, which blends smoothly into tone 3
// where the alpha is lowest. Reads
//   params[0].x    1 draws the edges of the mesh's triangles instead, in the tones' colors
//   params[0].y    the disc's segments (render.make_circle)
//   params[0].z    where the fire starts, a fraction of the disc's radius
//   params[0].w    the erosion threshold
//   params[1].rgb  tone 2
//   params[1].w    how far either side of the threshold the fire fades out
//   params[2].rgb  tone 1
//   params[3].rgb  tone 3

const TAU: f32 = 6.2831853;
// noise cells across a tile
const CELLS: i32 = 2;

// The gradient at lattice point cell, the lattice wrapping every period cells.
fn gradient(cell: vec2f, period: i32, seed: u32) -> vec2f {
    let size = f32(period);
    let c = vec2u(cell - size * floor(cell / size));
    var h = (c.x * 73856093u) ^ (c.y * 19349663u) ^ (seed * 83492791u);
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    let angle = f32(h & 0xffffu) / 65535.0 * TAU;
    return vec2f(cos(angle), sin(angle));
}

// Perlin noise at p, in lattice cells, repeating every period cells.
fn perlin(p: vec2f, period: i32, seed: u32) -> f32 {
    let cell = floor(p);
    let f = p - cell;
    let w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    let a = dot(gradient(cell, period, seed), f);
    let b = dot(gradient(cell + vec2f(1, 0), period, seed), f - vec2f(1, 0));
    let c = dot(gradient(cell + vec2f(0, 1), period, seed), f - vec2f(0, 1));
    let d = dot(gradient(cell + vec2f(1, 1), period, seed), f - vec2f(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Three octaves of Perlin noise at p, in tiles, repeating every `tiles` tiles, spread over 0
// to 1.
fn noise(q: vec2f, tiles: i32, seed: u32) -> f32 {
    var p = q * f32(CELLS);
    var period = tiles * CELLS;
    var sum = 0.0;
    var amplitude = 0.5;
    for (var k = 0; k < 3; k++) {
        sum += amplitude * perlin(p, period, seed);
        p *= 2.0;
        period *= 2;
        amplitude *= 0.5;
    }
    return clamp(0.5 + 1.2 * sum, 0.0, 1.0);
}

// noise layers: how big the noise is, and how fast it moves at SPEED
const LAYERS: i32 = 3;
var<private> LAYER: array<vec2f, 3> = array<vec2f, 3>(vec2f(1.0, 1.0), vec2f(2.0, 0.5), vec2f(0.5, 1.0));
// tiles of noise of size 1 across the surface
const TILES: f32 = 2.0;
// how fast the noise moves around the disc and outward, in turns and radii a second
const SPEED: vec2f = vec2f(0.08, -0.05);

// The layers' noise at `at` multiplied together.
fn fire_noise(at: vec2f, t: f32) -> f32 {
    var value = 1.0;
    for (var i = 0; i < LAYERS; i++) {
        let tiles = TILES / LAYER[i].x;
        value *= noise((at + t * LAYER[i].y * SPEED) * tiles, i32(tiles), u32(i));
    }
    return value;
}

// where tone 1 starts, and how wide its edge is
const EDGE: f32 = 0.7;
const EDGE_WIDTH: f32 = 0.03;

// The fire's color at alpha: tone 3 blending smoothly into tone 2, then a sharp fall off to
// tone 1.
fn fire_color(m: Material, alpha: f32) -> vec3f {
    let color = mix(m.params[3].rgb, m.params[1].rgb, smoothstep(0.0, EDGE, alpha));
    return mix(color, m.params[2].rgb, smoothstep(EDGE - EDGE_WIDTH, EDGE + EDGE_WIDTH, alpha));
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let m = node_material(in);
    let t = views[u.camera_index].time;
    let p = in.uv * 2.0 - 1.0;
    let r = length(p);
    let out_r = clamp((r - m.params[0].z) / (1.0 - m.params[0].z), 0.0, 1.0);
    let polar = vec2f(atan2(p.y, p.x) / TAU + 0.5, out_r);
    let above = fire_noise(polar, t) * smoothstep(0.0, 1.0, 1.0 - abs(2.0 * out_r - 1.0)) - m.params[0].w;
    let alpha = smoothstep(-m.params[1].w, m.params[1].w, above);

    // a fan: spokes every 1 / segments of a turn, closed by a chord
    let sector = TAU / m.params[0].y;
    let a = atan2(p.y, p.x) / sector;
    let fa = fract(a);
    let rim = cos(0.5 * sector) - r * cos((fa - 0.5) * sector);
    let edge = min(min(fa, 1.0 - fa) / fwidth(a), abs(rim) / fwidth(rim));

    if (m.params[0].x > 0.5) {
        if (edge > 0.75) {
            discard;
        }
        return vec4f(fire_color(m, alpha), 1.0);
    }
    if (alpha < 0.004) {
        discard;
    }
    return vec4f(fire_color(m, alpha), alpha);
}
