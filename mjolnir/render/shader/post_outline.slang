// OutlineEffect: edges where depth or normal change sharply.
struct Effect {
    float3 color;
    float thickness;
}
#include "post.slang"

float3 sample_normal(float2 uv)
{
    return normalize(post_normal(uv) * 2.0 - 1.0);
}

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    float4 scene = post_input(v.uv);
    float2 texel = e.thickness / post_resolution();
    float dc = post_depth(v.uv);
    // sky / background: no outline
    if (dc >= 1.0) {
        return float4(scene.rgb, 1.0);
    }
    float2 left = float2(-texel.x, 0.0);
    float2 right = float2(texel.x, 0.0);
    float2 up = float2(0.0, texel.y);
    float2 down = float2(0.0, -texel.y);
    float lc = linearize_depth(dc);
    float ll = linearize_depth(post_depth(v.uv + left));
    float lr = linearize_depth(post_depth(v.uv + right));
    float lu = linearize_depth(post_depth(v.uv + up));
    float ld = linearize_depth(post_depth(v.uv + down));
    // relative depth difference; the tolerance scales with distance so far objects stay
    // outlined
    float depth_diff = max(max(abs(lc - ll), abs(lc - lr)), max(abs(lc - lu), abs(lc - ld)));
    float depth_edge = smoothstep(0.02 * lc, 0.05 * lc + 0.01, depth_diff);
    float3 nc = sample_normal(v.uv);
    float normal_diff = (1.0 - dot(nc, sample_normal(v.uv + left))) + (1.0 - dot(nc, sample_normal(v.uv + right)))
        + (1.0 - dot(nc, sample_normal(v.uv + up))) + (1.0 - dot(nc, sample_normal(v.uv + down)));
    float normal_edge = smoothstep(0.4, 0.8, normal_diff);
    float edge = clamp(max(depth_edge, normal_edge), 0.0, 1.0);
    return float4(lerp(scene.rgb, e.color, edge), 1.0);
}
