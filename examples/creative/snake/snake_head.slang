// Shapes a sphere into the head: flat and long, tapering to the snout, the back of it at the
// node. Hands the fragment shader (up, along, around) of the head in color, around
// measured across the head in turns of the body.
#define CUSTOM_VERTEX
#include "snake_skin.slang"

static const float RADIUS = 0.45;
static const float3 SIZE = float3(1.3, 0.8, 1.9) * RADIUS;

[shader("vertex")]
VertexOut vs_main(VertexIn v)
{
    float3 p = normalize(v.position);
    float snout = clamp(-p.z, 0.0, 1.0);
    float3 size = SIZE * float3(1.0 - 0.4 * snout * snout, (1.0 - 0.25 * snout) * (p.y > 0.0 ? 1.0 : 0.8), 1.0);
    float3 position = p * size + float3(0.0, 0.8 * SIZE.y, -0.55 * SIZE.z);
    float3 normal = normalize(p / size);

    VertexOut o = material_vertex(v, position, normal);
    o.color = float4(p.y, position.z, position.x / (6.2831853 * RADIUS), 0.0);
    return o;
}
