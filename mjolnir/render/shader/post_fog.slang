// FogEffect: blends toward color between view depth start and end.
struct Effect {
    float3 color;
    float start;
    float end;
}
#include "post.slang"

float fog_factor(float distance)
{
    Effect e = effect();
    if (distance >= e.end) {
        return 1.0;
    }
    if (distance <= e.start) {
        return 0.0;
    }
    return clamp((distance - e.start) / (e.end - e.start), 0.0, 1.0);
}

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    float4 color = post_input(v.uv);
    float factor = fog_factor(linearize_depth(post_depth(v.uv)));
    return float4(lerp(color.rgb, effect().color, factor), 1.0);
}
