// GrayscaleEffect: desaturates toward luma by strength.
struct Effect {
    // zero = Rec. 601 luma
    float3 weights;
    float strength;
}
#include "post.slang"

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    float4 color = post_input(v.uv);
    float3 w = all(e.weights == float3(0.0)) ? float3(0.299, 0.587, 0.114) : e.weights;
    float gray = dot(color.rgb, w);
    return lerp(color, float4(gray, gray, gray, color.a), e.strength);
}
