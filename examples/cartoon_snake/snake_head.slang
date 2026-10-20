// Shapes a sphere into the head: flat and long, tapering to the snout, the back of it at the
// node. Reads
//   params[0].x  how far the jaw hangs open, in radians
// and hands the fragment shader (up, along, around, mouth) of the head in color, around
// measured across the head in turns of the body.
#define CUSTOM_VERTEX
#include "snake_skin.slang"

static const float RADIUS = 0.45;
static const float3 SIZE = float3(1.3, 0.8, 1.9) * RADIUS;
// the jaw's hinge, (y, z)
static const float2 HINGE = float2(0.8 * SIZE.y, -0.45);

[shader("vertex")]
VertexOut vs_main(VertexIn v)
{
    Material m = vertex_material(v);
    float jaw = m.params[0].x;
    float3 p = normalize(v.position);
    float snout = clamp(-p.z, 0.0, 1.0);
    float3 size = SIZE * float3(1.0 - 0.4 * snout * snout, (1.0 - 0.25 * snout) * (p.y > 0.0 ? 1.0 : 0.8), 1.0);
    float3 position = p * size + float3(0.0, HINGE.x, -0.55 * SIZE.z);
    float3 normal = normalize(p / size);

    float angle = jaw * step(p.y, -0.001) * (1.0 - smoothstep(HINGE.y - 0.1, HINGE.y + 0.2, position.z));
    // rows of the rotation: (cos, sin), (-sin, cos)
    float2x2 hang = float2x2(cos(angle), sin(angle), -sin(angle), cos(angle));
    position = float3(position.x, HINGE + mul(hang, position.yz - HINGE));
    normal = float3(normal.x, mul(hang, normal.yz));

    float mouth = step(abs(p.y), 0.001) * step(position.z, HINGE.y) * (1.0 + 8.0 * jaw);
    VertexOut o = material_vertex(v, position, normal);
    o.color = float4(p.y, position.z, position.x / (6.2831853 * RADIUS), mouth);
    return o;
}
