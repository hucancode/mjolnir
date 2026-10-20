// Wraps a sphere around the path the head slithered: its rings run neck to tail along a spline
// through the neck (the node) and the spine points behind it, the body pinching on the inside of
// a bend and leaning into it. Reads
//   params  the spine points, an (x, z) pair of halves each, evenly spaced down the body
// and hands the fragment shader (up, along, around, 0) of the body in color, around a fraction
// of a turn from the top.
#define CUSTOM_VERTEX
#include "snake_skin.slang"

static const int POINTS = 9;
static const float RADIUS = 0.45;

float girth(float t)
{
    return RADIUS * lerp(0.7, 1.0, smoothstep(0.0, 0.2, t)) * pow(1.0 - t, 0.7);
}

// Spine point i, the ends carried on straight.
float2 spine_point(float2 p[POINTS], int i)
{
    if (i < 0) return 2.0 * p[0] - p[1];
    if (i >= POINTS) return 2.0 * p[POINTS - 1] - p[POINTS - 2];
    return p[i];
}

[shader("vertex")]
VertexOut vs_main(VertexIn v)
{
    Material m = vertex_material(v);
    float2 p[POINTS];
    p[0] = float2(0.0);
    for (int j = 1; j < POINTS; j++) {
        uint half_pair = asuint(m.params[(j - 1) / 4][(j - 1) % 4]);
        p[j] = unpack_half2(half_pair);
    }
    float len = 0.0;
    for (int j = 1; j < POINTS; j++) len += distance(p[j - 1], p[j]);

    // a Catmull-Rom spline through the points, with its first two derivatives
    float t = clamp(v.uv.y, 0.001, 0.999);
    float u = t * float(POINTS - 1);
    int i = min(int(u), POINTS - 2);
    float f = u - float(i);
    float2 a = spine_point(p, i - 1);
    float2 b = p[i];
    float2 c = p[i + 1];
    float2 d = spine_point(p, i + 2);
    float2 c1 = c - a;
    float2 c2 = 2.0 * a - 5.0 * b + 4.0 * c - d;
    float2 c3 = -a + 3.0 * b - 3.0 * c + d;
    float2 center = b + 0.5 * (c1 * f + c2 * f * f + c3 * f * f * f);
    float2 d1 = 0.5 * (c1 + 2.0 * c2 * f + 3.0 * c3 * f * f);
    float2 d2 = 0.5 * (2.0 * c2 + 6.0 * c3 * f);
    float2 along = normalize(d1);
    float3 side = float3(along.y, 0.0, -along.x);
    // how hard the body bends toward `side`, in body widths
    float bend = clamp(-RADIUS * (d1.x * d2.y - d1.y * d2.x) / pow(length(d1), 3.0), -0.8, 0.8);

    float2 around = normalize(v.position.xz + float2(1e-5, 0.0));
    float inner = bend * around.x;
    float2 scale = float2(1.0 - 0.35 * inner, around.y < 0.0 ? 0.65 : 1.0 + 0.3 * max(inner, 0.0));
    float r = girth(t);
    float roll = 0.25 * bend;
    // rows of the rotation: (cos, sin), (-sin, cos)
    float2x2 lean = float2x2(cos(roll), sin(roll), -sin(roll), cos(roll));
    float2 offset = mul(lean, around * scale * r);
    float2 facing = mul(lean, normalize(around / scale));

    float3 position = float3(center.x, r * 0.65, center.y) + side * offset.x + float3(0.0, offset.y, 0.0);
    float3 normal = side * facing.x + float3(0.0, facing.y, 0.0);
    VertexOut o = material_vertex(v, position, normal);
    o.color = float4(around.y, t * len, atan2(around.x, around.y) / 6.2831853, 0.0);
    return o;
}
