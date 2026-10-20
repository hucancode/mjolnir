#version 450
// Breaks up a forcefield: a random few of the faceted sphere's quads
// (render.make_sphere(faceted = true)) stand out along their normal, by params[0].x (0 keeps
// the sphere whole). params[0].zw are the sphere's segments and rings.

#define MATERIAL_VERTEX
#include "material.glsl"

const float TAU = 6.2831853;
const float PI = 3.1415927;
// the share of quads popped out, and how far the farthest goes
const float CHANCE = 0.2;
const float DISTANCE = 0.3;

// A random number in 0 to 1 for the quad at cell, the n-th time it is asked.
float random(vec2 cell, float n) {
    uvec3 c = uvec3(uvec2(cell), uint(n));
    uint h = (c.x * 73856093u) ^ (c.y * 19349663u) ^ (c.z * 83492791u);
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    return float(h & 0xffffu) / 65535.0;
}

// How far out the quad at cell of a sphere of `rings` rings pops, from 0 to 1: most stay in
// place, and those around the poles always do.
float pop(vec2 cell, float rings) {
    bool polar = cell.y < 1.0 || cell.y > rings - 2.0;
    return !polar && random(cell, 0.0) < CHANCE ? 0.4 + 0.6 * random(cell, 1.0) : 0.0;
}

void main() {
    Material m = node_material();
    // every corner of a quad carries the normal through its center
    vec2 center = vec2(fract(atan(in_normal.z, in_normal.x) / TAU), acos(clamp(in_normal.y, -1.0, 1.0)) / PI);
    vec2 cell = floor(center * m.params[0].zw);
    vec3 p = in_position + in_normal * m.params[0].x * DISTANCE * pop(cell, m.params[0].w);
    material_vertex(p, in_normal);
}
