// Draws a bolt as a ribbon facing the camera, bent through the joints the CPU gives it. Each joint
// carries the width of the stroke there, and the width eases along each segment from one joint's to
// the next's, so it never jumps. The rod has uv spanning 0 to 1 across and the joint number
// along; the fragment draws a straight line across it, fading out smoothly: sharply at the line's
// edge at full sharpness, or more gradually the less sharpness there is, by the same distance for thin and thick alike.
struct Params {
    uint first;
}
#include "gpu.slang"

static const int JOINTS = 25;

struct Joint {
    float3 position;
    float width;
}

struct Bolt {
    float3 base;
    float radius;
    float3 top;
    // how much of the bolt's brightness this rod has
    float opacity;
    float3 right;
    float age;
    float leader;
    // intensity once the leader has reached the ground
    float trunk;
    // how thin and how thick the glow gets, against the ribbon's width
    float thin;
    float thick;
    // how crisp the line edge is, from 0 (fades out toward the ribbon border) to 1 (hard edge)
    float sharpness;
    // how many widths, evenly spread from thin to thick, the glow tends to
    float tones;
    float _pad1;
    float _pad2;
    float3 color;
    float _pad3;
    Joint joints[JOINTS];
}

[vk::binding(0, 1)] StructuredBuffer<Bolt> bolts;

struct VertexOut {
    float4 clip : SV_Position;
    // across the ribbon, from -1 to 1
    [vk::location(0)] float across : TEXCOORD0;
    // how thick the stroke is at either end of this segment, from 0 for thin to 1 for thick
    [vk::location(1)] nointerpolation float2 widths : TEXCOORD1;
    // how far along the segment this is
    [vk::location(4)] float along_segment : TEXCOORD4;
    // the ribbon's half width and the line's core width, in pixels, at its widest
    [vk::location(2)] float2 size : TEXCOORD2;
    [vk::location(3)] float intensity : TEXCOORD3;
    [vk::location(5)] nointerpolation float age : TEXCOORD5;
    [vk::location(6)] nointerpolation float3 tones : TEXCOORD6;
    // when the leader reaches the ground, and how far the soft edge fades out beyond the line, in pixels
    [vk::location(7)] nointerpolation float2 stroke : TEXCOORD7;
    [vk::location(8)] nointerpolation float3 color : TEXCOORD8;
    // the joint this segment starts at, how much of the bolt has eroded, and this rod's noise seed
    [vk::location(9)] nointerpolation float3 erode : TEXCOORD9;
}


// The width flares as the return stroke lands by this much, settling over this many seconds.
static const float WIDTH_FLARE = 0.6;
static const float FLARE_SETTLING = 0.15;
// the soft edge fades the line out over this many base line widths on either side of its edge at zero
// sharpness, however thick the line is there, and over this many pixels at full sharpness
static const float BORDER = 3.0;
static const float EDGE = 0.75;

// How wide the line is `along` a segment, against the ribbon's width. The thickness eases from the
// segment's start to its end, then settles onto the nearest of the evenly spread tones between thin
// and thick, easing between them so it never jumps, and the line flares as the return stroke lands.
float line_width(float2 widths, float along, float age, float3 range, float leader)
{
    float flare = age >= leader ? WIDTH_FLARE * exp(-(age - leader) / FLARE_SETTLING) : 0.0;
    float steps = max(range.z - 1.0, 1.0);
    float thickness = lerp(widths.x, widths.y, smoothstep(0.0, 1.0, along)) * steps;
    float lower = min(floor(thickness), steps - 1.0);
    float eased = smoothstep(0.25, 0.75, thickness - lower);
    return lerp(range.x, range.y, (lower + eased) / steps) * (1.0 + flare);
}

float2 safe_normalize(float2 v, float2 fallback)
{
    float l = length(v);
    return l > 1e-6 ? v / l : fallback;
}

// How bright the bolt is at a vertex the leader reaches `birth` of the way down: a spark as the
// leader passes, then flaring with each stroke.
float bolt_intensity(Bolt b, float birth)
{
    float reached = birth * b.leader;
    if (b.age < reached) return 0.0;
    if (b.age < b.leader) {
        float fresh = exp(-(b.age - reached) / 0.015);
        return 0.22 + fresh * 0.7;
    }
    return b.trunk;
}

// As the trunk dims the bolt erodes from its edges inward: the line gets thinner until it is gone.
// How much has eroded is 0 while the bolt is still bright and 1 once it is gone. Each point along
// the bolt erodes a little faster than the one before by up to this much, so it thins unevenly.
static const float ERODE_UNEVENNESS = 0.6;
static const float ERODE_COARSE = 9.0;
static const float ERODE_FINE = 37.0;

float hash11(float x)
{
    return frac(sin(x * 127.1 + 311.7) * 43758.5453);
}

float value_noise(float x, float seed)
{
    float cell = floor(x);
    float f = frac(x);
    f = f * f * (3.0 - 2.0 * f);
    return lerp(hash11(cell + seed), hash11(cell + 1.0 + seed), f);
}

float erosion_amount(Bolt b)
{
    return b.age >= b.leader ? 1.0 - saturate(b.trunk) : 0.0;
}

// How much of the line's width is left at `t` of the way up the bolt, from 0 (gone) to 1 (intact).
float erosion_remaining(float t, float seed, float eroded)
{
    float unevenness = 0.6 * value_noise(t * ERODE_COARSE, seed) + 0.4 * value_noise(t * ERODE_FINE, seed + 17.0);
    return saturate(1.0 - eroded * (1.0 + ERODE_UNEVENNESS * unevenness));
}

[shader("vertex")]
VertexOut vs_main(MeshVertex v, uint instance : SV_VulkanInstanceID)
{
    View view = views[gpu.camera_index];
    Bolt b = bolts[gpu.params.first + instance];
    int joint = int(v.uv.y);
    int first = v.normal.y > 0.0 ? joint : joint - 1;
    int before_joint = max(joint - 1, 0);
    int after_joint = min(joint + 1, JOINTS - 1);
    float3 center_rod = b.joints[joint].position;
    float3 previous = b.joints[before_joint].position;
    float3 next = b.joints[after_joint].position;
    float2 before = safe_normalize(center_rod.xy - previous.xy, float2(0.0, 1.0));
    float2 after = safe_normalize(next.xy - center_rod.xy, before);
    float2 heading = safe_normalize(before + after, after);
    float2 turned = float2(heading.y, -heading.x);
    float cos_half = sqrt((1.0 + dot(before, after)) * 0.5);
    float miter = min(1.0 / max(cos_half, 0.5), 2.0);
    float tan_half = sqrt(max(1.0 - cos_half * cos_half, 0.0)) / max(cos_half, 0.05);
    float shortest = min(length(center_rod - previous), length(next - center_rod));

    float3 axis = b.top - b.base;
    float height = length(axis);
    float3 up = axis / height;
    float3 depth = cross(b.right, up);
    float3 center = b.base + (b.right * center_rod.x + up * center_rod.y + depth * center_rod.z) * height;

    float4 clip_center = mul(view.view_projection, float4(center, 1.0));
    VertexOut o;
    o.across = 0.0;
    o.widths = float2(1.0);
    o.along_segment = v.color.x;
    o.size = float2(1.0);
    o.intensity = 0.0;
    o.age = b.age;
    o.tones = float3(b.thin, b.thick, b.tones);
    o.stroke = float2(b.leader, 0.0);
    o.color = b.color;
    o.erode = float3(float(first), erosion_amount(b), hash11(b.joints[3].position.x * 91.7 + b.joints[5].position.z * 53.3) * 100.0);
    if (clip_center.w < 0.3) {
        o.clip = CLIP_DISCARD;
        return o;
    }

    float3 to_eye = normalize(view.position.xyz - center);
    float3 across = normalize(cross(up, to_eye));
    float3 along = cross(to_eye, across);

    float focal = abs(view.projection[1][1]) * view.extent.y * 0.5;
    float plain = max(b.radius * focal / clip_center.w, 0.7);
    float spread = (1.0 - b.sharpness) * plain * BORDER;
    float core = max(plain * miter, 0.7);
    float widest = core * b.thick * (1.0 + WIDTH_FLARE);
    // as wide as the line gets, but not so wide that the inside of a sharp turn folds over itself
    // and draws twice
    float segment = shortest * height * focal / clip_center.w;
    float widest_reach = widest + spread + 2.0;
    float reach = clamp(min(widest_reach, segment * 0.9 / max(tan_half, 0.05)), 2.0, widest_reach);
    float side = v.uv.x * 2.0 - 1.0;
    float3 position = center + (across * turned.x + along * turned.y) * (side * reach * clip_center.w / focal);

    o.clip = clip_output(mul(view.view_projection, float4(position, 1.0)));
    o.across = side;
    o.widths = float2(b.joints[first].width, b.joints[first + 1].width);
    o.size = float2(reach, core);
    o.stroke.y = spread;
    o.intensity = bolt_intensity(b, saturate(1.0 - center_rod.y)) * b.opacity;
    return o;
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
    float t = (v.erode.x + v.along_segment) / float(JOINTS - 1);
    float left = erosion_remaining(t, v.erode.z, v.erode.y);
    float core = max(v.size.y * line_width(v.widths, v.along_segment, v.age, v.tones, v.stroke.x), 0.7) * left;
    float from_middle = abs(v.across) * v.size.x;
    float inner = max(core - EDGE - v.stroke.y, 0.0);
    float outer = max(min(core + EDGE + v.stroke.y, v.size.x), inner + 1e-3);
    float glow = 1.0 - smoothstep(inner, outer, from_middle);
    return float4(v.color * v.intensity * glow * smoothstep(0.0, 0.1, left), 0.0);
}
