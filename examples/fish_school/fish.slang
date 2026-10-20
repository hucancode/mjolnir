// Builds each fish from the vertex index: a body of SEGMENTS rings of SIDES vertices from nose
// to tail fin, bent side to side by its swim phase and turned along its velocity. Paints it: a
// hue of its own, dark stripes across the back, a silver belly, lit by the sun with caustics
// rippling over the top.
struct Params {
    uint first;
}
#include "gpu.slang"

struct Fish {
    float3 position;
    float phase;
    float3 velocity;
    float size;
}

[vk::binding(0, 1)] StructuredBuffer<Fish> fish;

struct VertexOut {
    float4 clip : SV_Position;
    [vk::location(0)] float3 position : POSITION;
    [vk::location(1)] float3 normal : NORMAL;
    [vk::location(2)] float2 body : TEXCOORD0;
    [vk::location(3)] nointerpolation uint fish : FISH;
}

static const uint SEGMENTS = 16;
static const uint SIDES = 10;
static const float2 CORNERS[6] = { float2(0, 0), float2(1, 0), float2(1, 1), float2(0, 0), float2(1, 1), float2(0, 1) };

// t runs from the nose (0) to the tail (1), a around the body.
float3 body(float t, float a, float phase)
{
    float height, width;
    if (t < 0.8) {
        float s = pow(sin(PI * t / 0.8), 0.7);
        height = 0.42 * s;
        width = 0.2 * s;
    } else {
        height = 0.55 * (t - 0.8) / 0.2;
        width = 0.03;
    }
    float3 p = float3(cos(a) * width, sin(a) * height, 0.5 - t);
    p.x += sin(t * 5.0 - phase) * 0.18 * t * t;
    return p;
}

[shader("vertex")]
VertexOut vs_main(uint vertex : SV_VulkanVertexID, uint instance : SV_VulkanInstanceID)
{
    uint quad = vertex / 6;
    float2 corner = CORNERS[vertex % 6];
    float t = (float(quad / SIDES) + corner.x) / float(SEGMENTS);
    float a = (float(quad % SIDES) + corner.y) / float(SIDES) * 2.0 * PI;
    Fish f = fish[gpu.params.first + instance];

    float3 p = body(t, a, f.phase);
    float3 n = normalize(cross(body(t + 0.01, a, f.phase) - p, body(t, a + 0.01, f.phase) - p));
    if (dot(n, float3(cos(a), sin(a), 0.0)) < 0.0) n = -n;

    float3 forward = normalize(f.velocity + float3(0.0, 0.0, 1e-4));
    float3 right = normalize(cross(float3(0.0, 1.0, 0.0), forward) + float3(1e-4, 0.0, 0.0));
    // the turn's columns are right, up, forward: p times the rows is the turn times p
    float3x3 turn = float3x3(right, cross(forward, right), forward);
    VertexOut o;
    o.position = f.position + mul(p, turn) * f.size * 2.0;
    o.normal = mul(n, turn);
    o.body = float2(t, sin(a));
    o.fish = instance;
    o.clip = clip_output(mul(views[gpu.camera_index].view_projection, float4(o.position, 1.0)));
    return o;
}

float3 hue(float h)
{
    return clamp(abs(frac(h + float3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
    View view = views[gpu.camera_index];
    float3 n = normalize(v.normal);
    float h = frac(float(v.fish) * 0.618034);
    float3 color = lerp(hue(h), float3(1.0, 0.7, 0.3), 0.35);
    color *= lerp(1.0, 0.35, step(0.55, frac(v.body.x * 6.0)) * step(0.0, v.body.y));
    color = lerp(color, float3(0.85, 0.88, 0.92), smoothstep(-0.1, -0.5, v.body.y));
    float sun = max(dot(n, view.sun_direction.xyz), 0.0);
    float ripple = 0.5 + 0.5 * sin(v.position.x * 2.3 + view.time * 1.7) * sin(v.position.z * 2.1 - view.time * 1.3);
    float3 lit = color * (view.sun_radiance.rgb * sun + 0.25) + pow(ripple, 4.0) * 0.5 * max(n.y, 0.0);
    return float4(lit, 1.0);
}
