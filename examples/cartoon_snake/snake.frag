#version 450
// Paints the snake: rows of overlapping scales, each lying over the front of the ones behind it
// and shading them, a zigzag down the back and speckles picked scale by scale, plated belly and
// the mouth, in toon bands of the sun with glossy glints and a rim light. Reads
// (up, along, around, mouth) from the vertex shader, around a fraction of a turn from the top.

#include "material.glsl"

const float AROUND = 22.0;
const float ROWS = 7.5;
const float SCALE = 0.72;

float hash(vec2 p) {
    return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// The scale in row k nearest g, every other row shifted half a scale.
vec2 scale_center(vec2 g, float k) {
    float shift = 0.5 * mod(k, 2.0);
    return vec2(floor(g.x - shift) + 0.5 + shift, k + 0.5);
}

void main() {
    Material m = node_material();
    View view = camera_view();
    float up = in_color.x;
    float along = in_color.y;
    vec3 n = normalize(in_normal);

    vec2 g = vec2(in_color.z * AROUND, along * ROWS);
    vec2 c = scale_center(g, floor(g.y) + 1.0);
    for (int k = 0; k >= -1; k--) {
        vec2 o = scale_center(g, floor(g.y) + float(k));
        c = distance(g, o) < SCALE ? o : c;
    }
    float d = distance(g, c) / SCALE;
    float front = distance(g, scale_center(g, c.y - 1.5)) / SCALE;

    vec2 at = c / vec2(AROUND, ROWS);
    float wave = (abs(fract(at.y * 1.6) - 0.5) - 0.25) * 0.2;
    float stripe = abs(at.x - wave) * AROUND * step(0.5, at.y);
    float speck = hash(c);
    vec3 skin = m.base_color_factor.rgb * (0.85 + 0.3 * hash(c + 17.0));
    skin = mix(skin, vec3(0.08, 0.12, 0.05), step(speck, 0.06));
    skin = mix(skin, vec3(0.1, 0.15, 0.06), step(stripe, 2.0) * step(0.5, at.y));
    skin = mix(skin, vec3(0.98, 0.78, 0.2), step(stripe, 1.0) * step(0.5, at.y));

    float rim = smoothstep(0.8 - fwidth(d), 0.95, d);
    float shadow = 1.0 - smoothstep(1.0, 1.3, front);
    skin *= (1.1 - 0.25 * d) * (1.0 - 0.4 * rim) * (1.0 - 0.35 * shadow);

    vec3 belly = vec3(1.0, 0.93, 0.65) * (1.0 - 0.3 * smoothstep(0.7, 0.95, fract(along * 5.0)));
    skin = mix(skin, belly, 1.0 - smoothstep(-0.5, -0.2, up));

    vec3 sun = view.sun_direction.xyz;
    vec3 eye = normalize(view.position.xyz - in_position);
    float light = floor(max(dot(n, sun), 0.0) * 3.0 + 0.5) / 3.0;
    vec3 color = skin * view.sun_radiance.rgb * mix(0.45, 1.0, light);
    float gloss = step(0.97, dot(n, normalize(sun + eye))) * (1.0 - d) * (1.0 - d);
    color += 0.4 * gloss * view.sun_radiance.rgb;
    color += 0.2 * step(0.7, 1.0 - max(dot(n, eye), 0.0));
    color = mix(color, vec3(0.55, 0.1, 0.15), step(0.5, in_color.w));
    out_color = vec4(color, 1.0);
}
