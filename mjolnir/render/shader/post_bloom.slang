// BloomEffect: pass 0 bright-passes and blurs horizontally, pass 1 blurs vertically and
// composites over the original (the image as it entered pass 0).
struct Effect {
    float threshold;
    float intensity;
    float blur_radius;
}
#include "post.slang"

static const float MAX_RADIUS = 64.0;

float luminance(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// UE4/Karis soft-knee bright-pass: a smooth transition around threshold avoids the hard
// cutoff that creates ringing and amplitude cliffs.
float3 soft_brightpass(float3 c, float lum, float threshold)
{
    float knee = threshold * 0.5;
    float soft = clamp(lum - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    float contribution = max(soft, lum - threshold) / max(lum, 1e-4);
    return c * contribution;
}

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    float2 texel_size = 1.0 / post_resolution();
    float radius = clamp(e.blur_radius, 1.0, MAX_RADIUS);
    // 3-sigma rule: the kernel decays to ~0 by the loop edge, so the truncated separable
    // Gaussian leaves no square halo
    float sigma = radius / 3.0;
    bool is_horizontal = post_push.pass_index == 0;
    float2 dir = is_horizontal ? float2(1.0, 0.0) : float2(0.0, 1.0);
    float3 acc = float3(0.0);
    float total = 0.0;
    for (float i = -radius; i <= radius; i += 1.0) {
        float3 c = post_input_level(v.uv + dir * i * texel_size).rgb;
        if (is_horizontal) {
            c = soft_brightpass(c, luminance(c), e.threshold);
        }
        float w = gaussian_weight(i, sigma);
        acc += c * w;
        total += w;
    }
    float3 blurred = acc / total;
    if (is_horizontal) {
        return float4(blurred, 1.0);
    }
    float3 original = post_original_level(v.uv).rgb;
    // soft additive: the blur attenuates where the original is already bright, so raising
    // intensity doesn't run away into saturation
    float3 boost = blurred * e.intensity;
    return float4(original + boost / (1.0 + 0.25 * boost), 1.0);
}
