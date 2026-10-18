#version 450
// Paints a fish: a hue of its own, dark stripes across the back, a silver belly, lit by the sun
// with caustics rippling over the top.

struct Params {
    uint first;
};
#include "gpu.glsl"

layout(location = 0) in vec3 in_position;
layout(location = 1) in vec3 in_normal;
layout(location = 2) in vec2 in_body;
layout(location = 3) flat in uint in_fish;

layout(location = 0) out vec4 out_color;

vec3 hue(float h) {
    return clamp(abs(fract(h + vec3(0.0, 2.0, 1.0) / 3.0) * 6.0 - 3.0) - 1.0, 0.0, 1.0);
}

void main() {
    View view = views[gpu.camera_index];
    vec3 n = normalize(in_normal);
    float h = fract(float(in_fish) * 0.618034);
    vec3 color = mix(hue(h), vec3(1.0, 0.7, 0.3), 0.35);
    color *= mix(1.0, 0.35, step(0.55, fract(in_body.x * 6.0)) * step(0.0, in_body.y));
    color = mix(color, vec3(0.85, 0.88, 0.92), smoothstep(-0.1, -0.5, in_body.y));
    float sun = max(dot(n, view.sun_direction.xyz), 0.0);
    float ripple = 0.5 + 0.5 * sin(in_position.x * 2.3 + view.time * 1.7) * sin(in_position.z * 2.1 - view.time * 1.3);
    vec3 lit = color * (view.sun_radiance.rgb * sun + 0.25) + pow(ripple, 4.0) * 0.5 * max(n.y, 0.0);
    out_color = vec4(lit, 1.0);
}
