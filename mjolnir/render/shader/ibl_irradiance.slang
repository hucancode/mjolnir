// Diffuse irradiance: the environment cube integrated over each texel's hemisphere, one
// sample per `value` radians of each angle.
#define IBL_SOURCE_CUBE 1
#include "ibl_common.slang"

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 gid : SV_DispatchThreadID)
{
    float3 n;
    if (!texel_dir(gid, n)) return;
    float3 up = abs(n.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0);
    float3 right = normalize(cross(up, n));
    up = normalize(cross(n, right));
    float3 irradiance = float3(0.0);
    float count = 0.0;
    float delta = max(precompute_push.value, 0.005);
    for (float phi = 0.0; phi < 2.0 * PI; phi += delta) {
        for (float theta = 0.0; theta < 0.5 * PI; theta += delta) {
            float s = sin(theta);
            float3 tangent = float3(s * cos(phi), s * sin(phi), cos(theta));
            float3 world = tangent.x * right + tangent.y * up + tangent.z * n;
            irradiance += sample_source(world) * cos(theta) * s;
            count += 1.0;
        }
    }
    irradiance = PI * irradiance / count;
    store_destination(gid, float4(irradiance, 1.0));
}
