// Draws what a strike throws up where it lands: a glowing disc and a glowing ring running out over
// the ground. One instance per impact, two quads of six vertices each.
struct Params {
    uint first;
}
#include "gpu.slang"

static const float DISC_LIFE = 0.2;
static const float RING_LIFE = 0.5;
static const float2 CORNERS[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0) };

struct Impact {
    float3 position;
    float age;
    float3 color;
    float power;
}

[vk::binding(0, 1)] StructuredBuffer<Impact> impacts;

struct VertexOut {
    float4 clip : SV_Position;
    [vk::location(0)] float2 uv : TEXCOORD0;
    // kind (0 disc, 1 ring, 2 spark), ring radius, ring width, brightness
    [vk::location(1)] nointerpolation float4 shape : TEXCOORD1;
    [vk::location(2)] nointerpolation float3 color : TEXCOORD2;
}

[shader("vertex")]
VertexOut vs_main(uint vertex : SV_VulkanVertexID, uint instance : SV_VulkanInstanceID)
{
    View view = views[gpu.camera_index];
    Impact im = impacts[gpu.params.first + instance];
    uint quad = vertex / 6;
    float2 corner = CORNERS[vertex % 6];
    float3 eye_right = float3(view.view[0].x, view.view[0].y, view.view[0].z);
    float3 eye_up = float3(view.view[1].x, view.view[1].y, view.view[1].z);
    float3 to_eye = normalize(view.position.xyz - im.position);

    VertexOut o;
    o.clip = CLIP_DISCARD;
    o.uv = corner;
    o.shape = float4(0.0, 0.0, 0.0, 0.0);
    o.color = im.color;

    if (quad == 0) {
        float t = im.age / DISC_LIFE;
        if (t >= 1.0) return o;
        float radius = im.power * lerp(0.1, 0.25, sqrt(t));
        float3 center = im.position + to_eye * radius;
        float3 p = center + (eye_right * corner.x + eye_up * corner.y) * radius;
        o.clip = clip_output(mul(view.view_projection, float4(p, 1.0)));
        o.shape = float4(0.0, 0.0, 0.0, 8.0 * (1.0 - t) * (1.0 - t));
    } else {
        float t = im.age / RING_LIFE;
        if (t >= 1.0) return o;
        float eased = 1.0 - pow(1.0 - t, 3.0);
        float radius = im.power * lerp(0.1, 0.8, eased);
        float width = lerp(0.08, 0.02, t) * im.power;
        float extent = radius + width * 3.0;
        float3 p = im.position + float3(corner.x, 0.03, corner.y) * extent;
        o.clip = clip_output(mul(view.view_projection, float4(p, 1.0)));
        o.uv = corner * extent;
        o.shape = float4(1.0, radius, width, 5.0 * (1.0 - t));
    }
    return o;
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
    float3 hot = float3(1.0, 1.0, 1.0);
    if (v.shape.x < 0.5) {
        float r = saturate(1.0 - length(v.uv));
        float glow = r * r;
        float core = r * r * r * r;
        return float4((v.color * glow + hot * core) * v.shape.w, 0.0);
    }
    float d = (length(v.uv) - v.shape.y) / v.shape.z;
    float glow = exp(-d * d);
    float core = exp(-d * d * 4.0);
    return float4((v.color * glow + hot * core * 0.5) * v.shape.w, 0.0);
}
