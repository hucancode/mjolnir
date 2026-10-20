// The environment cube from the equirect map.
#define IBL_SOURCE_CUBE 0
#include "ibl_common.slang"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 gid : SV_DispatchThreadID)
{
    float3 dir;
    if (!texel_dir(gid, dir)) return;
    float3 color = sample_source(dir_to_equirect_uv(dir));
    store_destination(gid, float4(color, 1.0));
}
