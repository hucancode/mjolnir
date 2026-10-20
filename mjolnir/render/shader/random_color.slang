// Random color: each triangle a color hashed from its index and the node, in the material's
// alpha. Vertex v of the draw is the mesh's index v.
#include "common.slang"

uint pulled_index(uint v)
{
    return v;
}
#include "mesh_pulled.slang"

float hash(uint v)
{
    uint x = ((v >> 16) ^ v) * 0x45d9f3bu;
    x = ((x >> 16) ^ x) * 0x45d9f3bu;
    x = (x >> 16) ^ x;
    return float(x) / 4294967295.0;
}

float3 hsv_to_rgb(float3 hsv)
{
    float3 k = hsv.x * 6.0 + float3(0.0, 4.0, 2.0);
    float3 rgb = clamp(abs(k - 6.0 * floor(k / 6.0) - 3.0) - 1.0, float3(0.0), float3(1.0));
    return hsv.z * lerp(float3(1.0), rgb, hsv.y);
}

[shader("fragment")]
float4 fs_main(PulledIn v
#if !BACKEND_WGPU
    , uint primitive : SV_PrimitiveID
#endif
) : SV_Target0
{
#if BACKEND_WGPU
    uint primitive = v.primitive;
#endif
    Material material = materials[nodes[v.node_index].material_id];
    uint seed = primitive ^ (v.node_index * 2654435761u);
    float h = hash(seed);
    float s = 0.7 + hash(seed + 1) * 0.3;
    float vv = 0.8 + hash(seed + 2) * 0.2;
    return float4(hsv_to_rgb(float3(h, s, vv)), material.base_color_factor.a);
}
