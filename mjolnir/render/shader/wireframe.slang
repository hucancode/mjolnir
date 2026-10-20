// Wireframe: a line list of every triangle edge in the vertex color. Vertex v of the draw is
// endpoint v % 2 of edge (v % 6) / 2 of triangle v / 6.
#include "common.slang"

uint pulled_index(uint v)
{
    uint corner = ((v % 6) / 2 + v % 2) % 3;
    return (v / 6) * 3 + corner;
}
#include "mesh_pulled.slang"

[shader("fragment")]
float4 fs_main(PulledIn v) : SV_Target0
{
    return float4(v.color.rgb, 1.0);
}
