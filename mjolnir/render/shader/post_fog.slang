// FogEffect: blends toward color between view depth start and end; above height the fog
// thins by exp(-height_falloff * the distance above), averaged along the view ray.
struct Effect {
    float3 color;
    float start;
    float end;
    float height;
    float height_falloff;
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

// The mean of min(exp(-k (y - height)), 1) along the ray from the camera at height y0 to y1.
float height_density(float y0, float y1, float height, float k)
{
    float a = max(y0 - height, 0.0);
    float b = max(y1 - height, 0.0);
    if (abs(b - a) < 1e-3) {
        return exp(-k * a);
    }
    return (exp(-k * a) - exp(-k * b)) / (k * (b - a));
}

[shader("fragment")]
float4 fs_main(PostIn v) : SV_Target0
{
    Effect e = effect();
    float4 color = post_input(v.uv);
    float depth = post_depth(v.uv);
    float factor = fog_factor(linearize_depth(depth));
    if (e.height_falloff > 0.0) {
        View camera = post_camera();
        factor *= height_density(camera.position.y, world_position(camera, v.uv, depth).y, e.height, e.height_falloff);
    }
    return float4(lerp(color.rgb, e.color, factor), 1.0);
}
