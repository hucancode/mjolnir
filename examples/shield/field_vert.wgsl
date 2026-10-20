// Breaks up a forcefield: a random few of the faceted sphere's quads
// (render.make_sphere(faceted = true)) stand out along their normal, by params[0].x (0 keeps
// the sphere whole). params[0].zw are the sphere's segments and rings.

const TAU: f32 = 6.2831853;
// the share of quads popped out, and how far the farthest goes
const CHANCE: f32 = 0.2;
const DISTANCE: f32 = 0.3;

// A random number in 0 to 1 for the quad at cell, the n-th time it is asked.
fn random(cell: vec2f, n: f32) -> f32 {
    let c = vec3u(vec2u(cell), u32(n));
    var h = (c.x * 73856093u) ^ (c.y * 19349663u) ^ (c.z * 83492791u);
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    return f32(h & 0xffffu) / 65535.0;
}

// How far out the quad at cell of a sphere of `rings` rings pops, from 0 to 1: most stay in
// place, and those around the poles always do.
fn pop(cell: vec2f, rings: f32) -> f32 {
    let polar = cell.y < 1.0 || cell.y > rings - 2.0;
    return select(0.0, 0.4 + 0.6 * random(cell, 1.0), !polar && random(cell, 0.0) < CHANCE);
}

@vertex
fn vs_main(in: VertexIn) -> VertexOut {
    let m = vertex_material(in);
    // every corner of a quad carries the normal through its center
    let center = vec2f(fract(atan2(in.normal.z, in.normal.x) / TAU), acos(clamp(in.normal.y, -1.0, 1.0)) / PI);
    let cell = floor(center * m.params[0].zw);
    let p = in.position + in.normal * m.params[0].x * DISTANCE * pop(cell, m.params[0].w);
    return material_vertex(in, p, in.normal);
}
