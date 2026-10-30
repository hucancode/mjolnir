// Paints the snake: rows of overlapping scales, each lying over the front of the ones behind it
// and shading them, a zigzag down the back and speckles picked scale by scale, plated belly, in toon
// bands of the sun with glossy glints and a rim light. Reads
// (up, along, around) from the vertex shader, around a fraction of a turn from the top.
// Shared by snake_body.slang and snake_head.slang.
#pragma once
#include "material.slang"

static const float AROUND = 22.0;
static const float ROWS = 7.5;
static const float SCALE = 0.72;

float hash(float2 p)
{
    return frac(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// The scale in row k nearest g, every other row shifted half a scale.
float2 scale_center(float2 g, float k)
{
    float shift = 0.5 * (k - 2.0 * floor(k / 2.0));
    return float2(floor(g.x - shift) + 0.5 + shift, k + 0.5);
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
    Material m = node_material(v);
    View view = camera_view();
    float up = v.color.x;
    float along = v.color.y;
    float3 n = normalize(v.normal);

    float2 g = float2(v.color.z * AROUND, along * ROWS);
    float2 c = scale_center(g, floor(g.y) + 1.0);
    for (int k = 0; k >= -1; k--) {
        float2 o = scale_center(g, floor(g.y) + float(k));
        c = distance(g, o) < SCALE ? o : c;
    }
    float d = distance(g, c) / SCALE;
    float front = distance(g, scale_center(g, c.y - 1.5)) / SCALE;

    float2 at = c / float2(AROUND, ROWS);
    float wave = (abs(frac(at.y * 1.6) - 0.5) - 0.25) * 0.2;
    float stripe = abs(at.x - wave) * AROUND * step(0.5, at.y);
    float speck = hash(c);
    float3 skin = m.base_color_factor.rgb * (0.85 + 0.3 * hash(c + 17.0));
    skin = lerp(skin, float3(0.08, 0.12, 0.05), step(speck, 0.06));
    skin = lerp(skin, float3(0.1, 0.15, 0.06), step(stripe, 2.0) * step(0.5, at.y));
    skin = lerp(skin, float3(0.98, 0.78, 0.2), step(stripe, 1.0) * step(0.5, at.y));

    float rim = smoothstep(0.8 - fwidth(d), 0.95, d);
    float shadow = 1.0 - smoothstep(1.0, 1.3, front);
    skin *= (1.1 - 0.25 * d) * (1.0 - 0.4 * rim) * (1.0 - 0.35 * shadow);

    float3 belly = float3(1.0, 0.93, 0.65) * (1.0 - 0.3 * smoothstep(0.7, 0.95, frac(along * 5.0)));
    skin = lerp(skin, belly, 1.0 - smoothstep(-0.5, -0.2, up));

    Sun sun = scene_sun();
    float3 eye = normalize(view.position.xyz - v.position);
    float light = floor(max(dot(n, sun.toward), 0.0) * 3.0 + 0.5) / 3.0;
    float3 color = skin * sun.radiance * lerp(0.45, 1.0, light);
    float gloss = step(0.97, dot(n, normalize(sun.toward + eye))) * (1.0 - d) * (1.0 - d);
    color += 0.4 * gloss * sun.radiance;
    color += 0.2 * step(0.7, 1.0 - max(dot(n, eye), 0.0));
    return float4(color, 1.0);
}
