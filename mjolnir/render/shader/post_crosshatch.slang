// CrossHatchEffect: pixels darker than lum_threshold i (tonemapped luminance) get stroke
// family i: the two diagonals, then both shifted by hatch_offset_y.

// lum_thresholds as scalars: the Odin array is tightly packed, uniform arrays are not
struct Effect {
    float hatch_offset_y;
    float lum_threshold0;
    float lum_threshold1;
    float lum_threshold2;
    float lum_threshold3;
}
#include "post.slang"

static const float HATCH_BRIGHTNESS = 0.65;
static const float STROKE_WIDTH = 1.5;
static const float STROKE_SPACING = 10.0;

// GLSL mod: floored, so negative coordinates repeat too
float stroke_mask(float coord)
{
    float m = coord - STROKE_SPACING * floor(coord / STROKE_SPACING);
    return step(m, STROKE_WIDTH);
}

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    float4 rgba = post_input(v.uv);
    float3 color = rgba.rgb;
    // tonemap luminance into [0, 1] so HDR scenes still hatch dark regions
    float raw_lum = dot(color, float3(0.2126, 0.7152, 0.0722));
    float lum = raw_lum / (raw_lum + 1.0);
    float2 screen_pos = v.uv * post_resolution();
    float a = screen_pos.x + screen_pos.y;
    float b = screen_pos.x - screen_pos.y;
    float offset = e.hatch_offset_y;
    float strokes[4] = { a, b, a - offset, b - offset };
    float thresholds[4] = { e.lum_threshold0, e.lum_threshold1, e.lum_threshold2, e.lum_threshold3 };
    float hatched = 1.0;
    for (int i = 0; i < 4; i++) {
        if (lum < thresholds[i] && stroke_mask(strokes[i]) > 0.5) {
            hatched = HATCH_BRIGHTNESS;
        }
    }
    return float4(color * hatched, rgba.a);
}
