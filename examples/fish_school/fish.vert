#version 450
// Builds each fish from the vertex index: a body of SEGMENTS rings of SIDES vertices from nose
// to tail fin, bent side to side by its swim phase and turned along its velocity.

struct Params {
    uint first;
};
#include "gpu.glsl"

struct Fish {
    vec3 position;
    float phase;
    vec3 velocity;
    float size;
};

layout(set = 1, binding = 0) readonly buffer School {
    Fish fish[];
};

layout(location = 0) out vec3 out_position;
layout(location = 1) out vec3 out_normal;
layout(location = 2) out vec2 out_body;
layout(location = 3) flat out uint out_fish;

const uint SEGMENTS = 16u;
const uint SIDES = 10u;
const float PI = 3.14159265;
const vec2 CORNERS[6] = vec2[](vec2(0, 0), vec2(1, 0), vec2(1, 1), vec2(0, 0), vec2(1, 1), vec2(0, 1));

// t runs from the nose (0) to the tail (1), a around the body.
vec3 body(float t, float a, float phase) {
    float height, width;
    if (t < 0.8) {
        float s = pow(sin(PI * t / 0.8), 0.7);
        height = 0.42 * s;
        width = 0.2 * s;
    } else {
        height = 0.55 * (t - 0.8) / 0.2;
        width = 0.03;
    }
    vec3 p = vec3(cos(a) * width, sin(a) * height, 0.5 - t);
    p.x += sin(t * 5.0 - phase) * 0.18 * t * t;
    return p;
}

void main() {
    uint quad = gl_VertexIndex / 6u;
    vec2 corner = CORNERS[gl_VertexIndex % 6u];
    float t = (float(quad / SIDES) + corner.x) / float(SEGMENTS);
    float a = (float(quad % SIDES) + corner.y) / float(SIDES) * 2.0 * PI;
    Fish f = fish[gpu.params.first + gl_InstanceIndex];

    vec3 p = body(t, a, f.phase);
    vec3 n = normalize(cross(body(t + 0.01, a, f.phase) - p, body(t, a + 0.01, f.phase) - p));
    if (dot(n, vec3(cos(a), sin(a), 0.0)) < 0.0) n = -n;

    vec3 forward = normalize(f.velocity + vec3(0.0, 0.0, 1e-4));
    vec3 right = normalize(cross(vec3(0.0, 1.0, 0.0), forward) + vec3(1e-4, 0.0, 0.0));
    mat3 turn = mat3(right, cross(forward, right), forward);
    out_position = f.position + turn * p * f.size * 2.0;
    out_normal = turn * n;
    out_body = vec2(t, sin(a));
    out_fish = gl_InstanceIndex;
    gl_Position = views[gpu.camera_index].view_projection * vec4(out_position, 1.0);
}
