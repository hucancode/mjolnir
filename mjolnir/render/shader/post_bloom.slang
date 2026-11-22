// BloomEffect, in steps (render's pass_post.odin BloomStep, pass_index): FIRST_DOWN takes the
// bright part of the image into the first half-sized level, DOWN halves a level into the next,
// UP spreads a level into the one above (added to it by the pipeline's blending), COMPOSITE adds
// the first level over the image (post_second) as glow, over the number of levels (pass_index
// above its low 4 bits) the up steps summed into it.
struct Effect {
    // zero is white
    float3 tint;
    float threshold;
    float intensity;
    float radius;
}
#include "post.slang"

static const uint FIRST_DOWN = 0;
static const uint DOWN = 1;
static const uint UP = 2;

float luminance(float3 color)
{
    return dot(color, float3(0.2126, 0.7152, 0.0722));
}

// UE4/Karis soft-knee bright-pass: a smooth transition around threshold avoids the hard cutoff
// that creates ringing and amplitude cliffs.
float3 soft_brightpass(float3 c, float threshold)
{
    float lum = luminance(c);
    float knee = threshold * 0.5;
    float soft = clamp(lum - threshold + knee, 0.0, 2.0 * knee);
    soft = soft * soft / (4.0 * knee + 1e-4);
    return c * max(soft, lum - threshold) / max(lum, 1e-4);
}

// 13 taps of the level above, weighted so a bright texel spreads without flicker (Jimenez 2014).
float3 downsample(float2 uv)
{
    float2 t = 1.0 / post_resolution();
    float3 a = post_input_level(uv + t * float2(-2, 2)).rgb;
    float3 b = post_input_level(uv + t * float2(0, 2)).rgb;
    float3 c = post_input_level(uv + t * float2(2, 2)).rgb;
    float3 d = post_input_level(uv + t * float2(-2, 0)).rgb;
    float3 e = post_input_level(uv).rgb;
    float3 f = post_input_level(uv + t * float2(2, 0)).rgb;
    float3 g = post_input_level(uv + t * float2(-2, -2)).rgb;
    float3 h = post_input_level(uv + t * float2(0, -2)).rgb;
    float3 i = post_input_level(uv + t * float2(2, -2)).rgb;
    float3 j = post_input_level(uv + t * float2(-1, 1)).rgb;
    float3 k = post_input_level(uv + t * float2(1, 1)).rgb;
    float3 l = post_input_level(uv + t * float2(-1, -1)).rgb;
    float3 m = post_input_level(uv + t * float2(1, -1)).rgb;
    return e * 0.125 + (a + c + g + i) * 0.03125 + (b + d + f + h) * 0.0625 + (j + k + l + m) * 0.125;
}

// A 3x3 tent over the level below, `radius` of its texels apart.
float3 upsample(float2 uv, float radius)
{
    float2 t = radius / post_resolution();
    float3 s = post_input_level(uv).rgb * 4.0;
    s += (post_input_level(uv + t * float2(-1, 0)).rgb + post_input_level(uv + t * float2(1, 0)).rgb +
          post_input_level(uv + t * float2(0, -1)).rgb + post_input_level(uv + t * float2(0, 1)).rgb) * 2.0;
    s += post_input_level(uv + t * float2(-1, -1)).rgb + post_input_level(uv + t * float2(1, -1)).rgb +
         post_input_level(uv + t * float2(-1, 1)).rgb + post_input_level(uv + t * float2(1, 1)).rgb;
    return s / 16.0;
}

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    uint step = post_push.pass_index & 0xF;
    float levels = float(max(post_push.pass_index >> 4, 1u));
    if (step == FIRST_DOWN) {
        return float4(soft_brightpass(downsample(v.uv), e.threshold), 1.0);
    }
    if (step == DOWN) {
        return float4(downsample(v.uv), 1.0);
    }
    if (step == UP) {
        return float4(upsample(v.uv, e.radius > 0.0 ? e.radius : 1.0), 1.0);
    }
    float3 tint = any(e.tint != float3(0.0)) ? e.tint : float3(1.0);
    float3 glow = post_second(v.uv).rgb * e.intensity * tint / levels;
    float3 original = post_input(v.uv).rgb;
    // soft additive: the glow attenuates where the original is already bright, so raising
    // intensity doesn't run away into saturation
    return float4(original + glow / (1.0 + 0.25 * glow), 1.0);
}
