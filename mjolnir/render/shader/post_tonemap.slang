// ToneMapEffect: exposure tonemap. The sRGB view of the presented image encodes; gamma is
// kept as additional curve shaping (1.0 = off).
struct Effect {
    float exposure;
    float gamma;
}
#include "post.slang"

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    float3 color = post_input(v.uv).rgb;
    color = float3(1.0) - exp(-color * e.exposure);
    if (e.gamma > 0.0 && abs(e.gamma - 1.0) > 1e-4) {
        color = pow(color, float3(1.0 / e.gamma));
    }
    return float4(color, 1.0);
}
