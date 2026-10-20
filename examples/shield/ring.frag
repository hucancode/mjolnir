#version 450
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

#include "material.glsl"

const float TAU = 6.2831853;
// noise cells across a tile
const int CELLS = 2;

// The gradient at lattice point cell, the lattice wrapping every period cells.
vec2 gradient(vec2 cell, int period, uint seed) {
    uvec2 c = uvec2(mod(cell, float(period)));
    uint h = (c.x * 73856093u) ^ (c.y * 19349663u) ^ (seed * 83492791u);
    h = (h ^ (h >> 13u)) * 1274126177u;
    h ^= h >> 16u;
    float angle = float(h & 0xffffu) / 65535.0 * TAU;
    return vec2(cos(angle), sin(angle));
}

// Perlin noise at p, in lattice cells, repeating every period cells.
float perlin(vec2 p, int period, uint seed) {
    vec2 cell = floor(p);
    vec2 f = p - cell;
    vec2 w = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
    float a = dot(gradient(cell, period, seed), f);
    float b = dot(gradient(cell + vec2(1, 0), period, seed), f - vec2(1, 0));
    float c = dot(gradient(cell + vec2(0, 1), period, seed), f - vec2(0, 1));
    float d = dot(gradient(cell + vec2(1, 1), period, seed), f - vec2(1, 1));
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

// Three octaves of Perlin noise at p, in tiles, repeating every `tiles` tiles, spread over 0
// to 1.
float noise(vec2 p, int tiles, uint seed) {
    p *= float(CELLS);
    int period = tiles * CELLS;
    float sum = 0.0;
    float amplitude = 0.5;
    for (int k = 0; k < 3; k++) {
        sum += amplitude * perlin(p, period, seed);
        p *= 2.0;
        period *= 2;
        amplitude *= 0.5;
    }
    return clamp(0.5 + 1.2 * sum, 0.0, 1.0);
}

// noise layers: how big the noise is, and how fast it moves at SPEED
const int LAYERS = 3;
const vec2 LAYER[LAYERS] = vec2[](vec2(1.0, 1.0), vec2(2.0, 0.5), vec2(0.5, 1.0));
// tiles of noise of size 1 across the surface
const float TILES = 2.0;
// how fast the noise moves around the disc and outward, in turns and radii a second
const vec2 SPEED = vec2(0.08, -0.05);

// The layers' noise at `at` multiplied together.
float fire_noise(vec2 at, float t) {
    float value = 1.0;
    for (int i = 0; i < LAYERS; i++) {
        float tiles = TILES / LAYER[i].x;
        value *= noise((at + t * LAYER[i].y * SPEED) * tiles, int(tiles), uint(i));
    }
    return value;
}

// where tone 1 starts, and how wide its edge is
const float EDGE = 0.7;
const float EDGE_WIDTH = 0.03;

// The fire's color at alpha: tone 3 blending smoothly into tone 2, then a sharp fall off to
// tone 1.
vec3 fire_color(Material m, float alpha) {
    vec3 color = mix(m.params[3].rgb, m.params[1].rgb, smoothstep(0.0, EDGE, alpha));
    return mix(color, m.params[2].rgb, smoothstep(EDGE - EDGE_WIDTH, EDGE + EDGE_WIDTH, alpha));
}

void main() {
    Material m = node_material();
    float t = camera_view().time;
    vec2 p = in_uv * 2.0 - 1.0;
    float r = length(p);
    float out_r = clamp((r - m.params[0].z) / (1.0 - m.params[0].z), 0.0, 1.0);
    vec2 polar = vec2(atan(p.y, p.x) / TAU + 0.5, out_r);
    float above = fire_noise(polar, t) * smoothstep(0.0, 1.0, 1.0 - abs(2.0 * out_r - 1.0)) - m.params[0].w;
    float alpha = smoothstep(-m.params[1].w, m.params[1].w, above);

    // a fan: spokes every 1 / segments of a turn, closed by a chord
    float sector = TAU / m.params[0].y;
    float a = atan(p.y, p.x) / sector;
    float fa = fract(a);
    float rim = cos(0.5 * sector) - r * cos((fa - 0.5) * sector);
    float edge = min(min(fa, 1.0 - fa) / fwidth(a), abs(rim) / fwidth(rim));

    if (m.params[0].x > 0.5) {
        if (edge > 0.75) discard;
        out_color = vec4(fire_color(m, alpha), 1.0);
        return;
    }
    if (alpha < 0.004) discard;
    out_color = vec4(fire_color(m, alpha), alpha);
}
