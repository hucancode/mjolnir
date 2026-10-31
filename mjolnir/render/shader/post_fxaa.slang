// render.FXAAEffect: the image with its edges smoothed (after Timothy Lottes' FXAA 3.11, quality
// preset 12). Edges are found on the luma of the colour compressed by c / (1 + c), so the HDR
// highlights do not hide the dim edges, and gamma-encoded by sqrt, as FXAA's thresholds expect;
// the blend itself stays in HDR.
struct Effect {
    // render.FXAAEffect
    float edge_threshold;
    float edge_threshold_min;
    float subpixel;
    uint search_steps;
}
#include "post.slang"

// the steps walking along an edge to its ends, in texels, then the guess past the last
static const uint SEARCH_STEPS = 10;
static const float STEP_SIZES[SEARCH_STEPS] = { 1.0, 1.5, 2.0, 2.0, 2.0, 2.0, 2.0, 2.0, 4.0, 8.0 };
static const float LAST_GUESS = 8.0;

float edge_luma(float3 color)
{
    return dot(sqrt(color / (1.0 + color)), float3(0.299, 0.587, 0.114));
}

float luma_at(float2 uv)
{
    return edge_luma(post_input_level(uv).rgb);
}

// Walks from uv along step until the luma along the edge leaves edge_value by threshold;
// returns where it stopped and, in delta, the luma there minus edge_value.
float2 edge_end(float2 uv, float2 step, float edge_value, float threshold, out float delta)
{
    delta = 0.0;
    for (uint i = 0; i < min(effect().search_steps, SEARCH_STEPS); i++) {
        uv += step * STEP_SIZES[i];
        delta = luma_at(uv) - edge_value;
        if (abs(delta) >= threshold) return uv;
    }
    return uv + step * LAST_GUESS;
}

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    float4 center = post_input_level(v.uv);

    float2 texel = 1.0 / post_resolution();
    float m = edge_luma(center.rgb);
    float n = luma_at(v.uv + float2(0.0, -texel.y));
    float s = luma_at(v.uv + float2(0.0, texel.y));
    float e = luma_at(v.uv + float2(texel.x, 0.0));
    float w = luma_at(v.uv + float2(-texel.x, 0.0));
    float lo = min(m, min(min(n, s), min(e, w)));
    float hi = max(m, max(max(n, s), max(e, w)));
    float range = hi - lo;
    if (range < max(effect().edge_threshold_min, hi * effect().edge_threshold)) return center;

    float ne = luma_at(v.uv + float2(texel.x, -texel.y));
    float nw = luma_at(v.uv - texel);
    float se = luma_at(v.uv + texel);
    float sw = luma_at(v.uv + float2(-texel.x, texel.y));

    // a lone pixel unlike its neighbourhood blends toward it
    float average = (2.0 * (n + s + e + w) + ne + nw + se + sw) / 12.0;
    float subpixel = smoothstep(0.0, 1.0, saturate(abs(average - m) / range));
    subpixel = subpixel * subpixel * effect().subpixel;

    // the edge runs along the direction of least change
    float horizontal = abs(nw + ne - 2.0 * n) + 2.0 * abs(w + e - 2.0 * m) + abs(sw + se - 2.0 * s);
    float vertical = abs(nw + sw - 2.0 * w) + 2.0 * abs(n + s - 2.0 * m) + abs(ne + se - 2.0 * e);
    bool is_horizontal = horizontal >= vertical;

    // the side across the edge with the larger change
    float positive = is_horizontal ? s : e;
    float negative = is_horizontal ? n : w;
    float across = is_horizontal ? texel.y : texel.x;
    float opposite = positive;
    float gradient = abs(positive - m);
    if (abs(negative - m) > gradient) {
        across = -across;
        opposite = negative;
        gradient = abs(negative - m);
    }

    // walk both ways along the edge, half a texel across, to its ends
    float2 on_edge = v.uv + (is_horizontal ? float2(0.0, across) : float2(across, 0.0)) * 0.5;
    float2 along = is_horizontal ? float2(texel.x, 0.0) : float2(0.0, texel.y);
    float edge_value = (m + opposite) * 0.5;
    float threshold = gradient * 0.25;
    float positive_delta, negative_delta;
    float2 positive_end = edge_end(on_edge, along, edge_value, threshold, positive_delta);
    float2 negative_end = edge_end(on_edge, -along, edge_value, threshold, negative_delta);
    float positive_distance = is_horizontal ? positive_end.x - v.uv.x : positive_end.y - v.uv.y;
    float negative_distance = is_horizontal ? v.uv.x - negative_end.x : v.uv.y - negative_end.y;

    // nearer the end where the edge turns away from this pixel's side, blend more across it
    float nearest = min(positive_distance, negative_distance);
    float end_delta = positive_distance <= negative_distance ? positive_delta : negative_delta;
    float edge_blend = (end_delta >= 0.0) == (m - edge_value >= 0.0) ? 0.0 : 0.5 - nearest / (positive_distance + negative_distance);

    float blend = max(subpixel, edge_blend);
    float2 offset = (is_horizontal ? float2(0.0, across) : float2(across, 0.0)) * blend;
    return float4(post_input_level(v.uv + offset).rgb, center.a);
}
