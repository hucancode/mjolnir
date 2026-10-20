// A user post-process shader: darkens toward `color` away from the screen center.
struct Effect { float3 color; float radius; float softness; float strength; }
#include "post.slang"

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    float4 scene = post_input(v.uv);
    float d = length(v.uv - 0.5);
    float vignette = 1.0 - smoothstep(e.radius - e.softness, e.radius, d);
    return float4(lerp(e.color, scene.rgb, lerp(1.0, vignette, e.strength)), 1.0);
}
