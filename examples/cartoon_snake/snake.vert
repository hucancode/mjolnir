#version 450
// Wraps a sphere around the path the head slithered: its rings run neck to tail along a spline
// through the neck (the node) and the spine points behind it, the body pinching on the inside of
// a bend and leaning into it. Reads
//   params  the spine points, an (x, z) pair of halves each, evenly spaced down the body
// and hands the fragment shader (up, along, around, 0) of the body in out_color, around a
// fraction of a turn from the top.

#define MATERIAL_VERTEX
#include "material.glsl"

const int POINTS = 9;
const float RADIUS = 0.45;

float girth(float t) {
    return RADIUS * mix(0.7, 1.0, smoothstep(0.0, 0.2, t)) * pow(1.0 - t, 0.7);
}

// Spine point i, the ends carried on straight.
vec2 spine_point(vec2 p[POINTS], int i) {
    if (i < 0) return 2.0 * p[0] - p[1];
    if (i >= POINTS) return 2.0 * p[POINTS - 1] - p[POINTS - 2];
    return p[i];
}

void main() {
    Material m = node_material();
    vec2 p[POINTS];
    p[0] = vec2(0.0);
    for (int i = 1; i < POINTS; i++) {
        p[i] = unpackHalf2x16(floatBitsToUint(m.params[(i - 1) / 4][(i - 1) % 4]));
    }
    float len = 0.0;
    for (int i = 1; i < POINTS; i++) len += distance(p[i - 1], p[i]);

    // a Catmull-Rom spline through the points, with its first two derivatives
    float t = clamp(in_uv.y, 0.001, 0.999);
    float u = t * float(POINTS - 1);
    int i = min(int(u), POINTS - 2);
    float f = u - float(i);
    vec2 a = spine_point(p, i - 1);
    vec2 b = p[i];
    vec2 c = p[i + 1];
    vec2 d = spine_point(p, i + 2);
    vec2 c1 = c - a;
    vec2 c2 = 2.0 * a - 5.0 * b + 4.0 * c - d;
    vec2 c3 = -a + 3.0 * b - 3.0 * c + d;
    vec2 center = b + 0.5 * (c1 * f + c2 * f * f + c3 * f * f * f);
    vec2 d1 = 0.5 * (c1 + 2.0 * c2 * f + 3.0 * c3 * f * f);
    vec2 d2 = 0.5 * (2.0 * c2 + 6.0 * c3 * f);
    vec2 along = normalize(d1);
    vec3 side = vec3(along.y, 0.0, -along.x);
    // how hard the body bends toward `side`, in body widths
    float bend = clamp(-RADIUS * (d1.x * d2.y - d1.y * d2.x) / pow(length(d1), 3.0), -0.8, 0.8);

    vec2 around = normalize(in_position.xz + vec2(1e-5, 0.0));
    float inner = bend * around.x;
    vec2 scale = vec2(1.0 - 0.35 * inner, around.y < 0.0 ? 0.65 : 1.0 + 0.3 * max(inner, 0.0));
    float r = girth(t);
    float roll = 0.25 * bend;
    mat2 lean = mat2(cos(roll), -sin(roll), sin(roll), cos(roll));
    vec2 offset = lean * (around * scale * r);
    vec2 facing = lean * normalize(around / scale);

    vec3 position = vec3(center.x, r * 0.65, center.y) + side * offset.x + vec3(0.0, offset.y, 0.0);
    vec3 normal = side * facing.x + vec3(0.0, facing.y, 0.0);
    material_vertex(position, normal);
    out_color = vec4(around.y, t * len, atan(around.x, around.y) / 6.2831853, 0.0);
}
