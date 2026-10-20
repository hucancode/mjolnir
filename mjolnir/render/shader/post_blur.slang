// BlurEffect: separable blur, pass 0 horizontal, pass 1 vertical.
struct Effect {
    float radius;
    // 0.0 = box blur, 1.0 = gaussian blur
    float weight_falloff;
}
#include "post.slang"

static const float MAX_RADIUS = 16.0;

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    float2 texel_size = 1.0 / post_resolution();
    float4 color = float4(0.0);
    float total_weight = 0.0;
    float blur_radius = clamp(e.radius, 1.0, MAX_RADIUS);
    float sigma = blur_radius * 0.3;
    float2 direction = post_push.pass_index == 0 ? float2(1.0, 0.0) : float2(0.0, 1.0);
    // step by 0.5 for smoother results
    for (float i = -blur_radius; i <= blur_radius; i += 0.5) {
        float2 offset = direction * i * texel_size;
        // weight_falloff blends a box (0) into a Gaussian (1)
        float weight = lerp(1.0, gaussian_weight(i, sigma), e.weight_falloff);
        color += post_input_level(v.uv + offset) * weight;
        total_weight += weight;
    }
    return color / total_weight;
}
