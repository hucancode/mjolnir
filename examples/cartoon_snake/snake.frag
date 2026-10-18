#version 450
// Paints the snake: overlapping scales, a zigzag down the back, a pale belly and two eyes, in
// toon bands of the sun with a rim light.

#include "material.glsl"

float eye(float t, float up, float side, float len) {
    float across = acos(clamp(dot(normalize(vec2(abs(side), up)), vec2(0.8, 0.6)), -1.0, 1.0));
    return length(vec2((t - 0.055) * len, across * 0.5));
}

void main() {
    Material m = node_material();
    View view = camera_view();
    float up = in_color.x;
    float t = in_color.y;
    float len = unpackHalf2x16(floatBitsToUint(m.params[0].z)).x;
    vec3 n = normalize(in_normal);

    vec2 cell = vec2(in_uv.x * 28.0, t * 90.0);
    cell.x += 0.5 * mod(floor(cell.y), 2.0);
    vec3 skin = m.base_color_factor.rgb * (1.0 - 0.3 * smoothstep(0.3, 0.5, length(fract(cell) - 0.5)));
    float zig = abs(fract(t * 14.0) - 0.5) * 0.6;
    skin = mix(skin, vec3(0.98, 0.78, 0.2), step(0.85 - zig, up) * step(0.12, t));
    skin = mix(skin, vec3(1.0, 0.93, 0.65), smoothstep(-0.2, -0.5, up));

    float light = floor(max(dot(n, view.sun_direction.xyz), 0.0) * 3.0 + 0.5) / 3.0;
    vec3 color = skin * view.sun_radiance.rgb * mix(0.45, 1.0, light);
    float rim = 1.0 - max(dot(n, normalize(view.position.xyz - in_position)), 0.0);
    color += 0.2 * step(0.7, rim);

    float d = eye(t, up, in_color.z, len);
    color = mix(color, vec3(1.0), step(d, 0.11));
    color = mix(color, vec3(0.02), step(eye(t + 0.006, up, in_color.z, len), 0.055));
    out_color = vec4(color, 1.0);
}
