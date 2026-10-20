// Breaks up a forcefield: a random few of the faceted sphere's quads
// (render.make_sphere(faceted = true)) stand out along their normal, by params[0].x (0 keeps
// the sphere whole). params[0].zw are the sphere's segments and rings.
//
// Lights a forcefield of solid glowing panels: each quad of the faceted sphere has a bright
// frame and an inset trim, flickers on its own, flares where it pops out, and brightens toward
// the silhouette. Reads
//   params[0].x    1 pops quads out
//   params[0].y    1 draws the edges of the mesh's triangles instead
//   params[0].zw   the sphere's segments and rings (render.make_sphere)
//   params[2].rgb  the color of the field
#define CUSTOM_VERTEX
#include "material.slang"

static const float TAU = 6.2831853;
// the share of quads popped out, and how far the farthest goes
static const float CHANCE = 0.2;
static const float DISTANCE = 0.3;

// A random number in 0 to 1 for the quad at cell, the n-th time it is asked.
float random(float2 cell, float n)
{
    uint3 c = uint3(uint2(cell), uint(n));
    uint h = (c.x * 73856093u) ^ (c.y * 19349663u) ^ (c.z * 83492791u);
    h = (h ^ (h >> 13)) * 1274126177u;
    h ^= h >> 16;
    return float(h & 0xffffu) / 65535.0;
}

// How far out the quad at cell of a sphere of `rings` rings pops, from 0 to 1: most stay in
// place, and those around the poles always do.
float pop(float2 cell, float rings)
{
    bool polar = cell.y < 1.0 || cell.y > rings - 2.0;
    return !polar && random(cell, 0.0) < CHANCE ? 0.4 + 0.6 * random(cell, 1.0) : 0.0;
}

[shader("vertex")]
VertexOut vs_main(VertexIn v)
{
    Material m = vertex_material(v);
    // every corner of a quad carries the normal through its center
    float2 center = float2(frac(atan2(v.normal.z, v.normal.x) / TAU), acos(clamp(v.normal.y, -1.0, 1.0)) / PI);
    float2 cell = floor(center * m.params[0].zw);
    float3 p = v.position + v.normal * m.params[0].x * DISTANCE * pop(cell, m.params[0].w);
    return material_vertex(v, p, v.normal);
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
    Material m = node_material(v);
    View view = camera_view();
    float t = view.time;
    float2 g = v.uv * m.params[0].zw;
    float2 cell = floor(g);
    float2 f = g - cell;
    float2 w = fwidth(g);
    // pixels to the quad's border, and to its trim a fifth of the way in
    float2 border = min(f, 1.0 - f) / w;
    float frame = min(border.x, border.y);
    float2 inside = min(f, 1.0 - f) - 0.2;
    float trim = abs(min(inside.x / w.x, inside.y / w.y));
    float diagonal = abs(f.x + f.y - 1.0) / fwidth(g.x + g.y);
    float3 color = m.params[2].rgb;

    if (m.params[0].y > 0.5) {
        if (min(frame, diagonal) > 0.75) discard;
        return float4(color * 2.0, 1.0);
    }
    float popped = m.params[0].x * pop(cell, m.params[0].w);
    float flicker = 0.75 + 0.25 * sin(t * (2.0 + 3.0 * random(cell, 7.0)) + TAU * random(cell, 9.0));
    float facing = abs(dot(normalize(v.normal), normalize(view.position.xyz - v.position)));
    float rim = pow(1.0 - facing, 3.0);
    float lines = 1.0 - smoothstep(0.0, 1.5, frame);
    float trims = 1.0 - smoothstep(0.0, 1.0, trim);

    float light = 0.1 * flicker + 0.6 * rim + 0.35 * trims * flicker + 2.5 * lines + 1.5 * popped;
    return float4(color * light, 1.0);
}
