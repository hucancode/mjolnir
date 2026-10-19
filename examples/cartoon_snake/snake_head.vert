#version 450
// Shapes a sphere into the head: flat and long, tapering to the snout, the back of it at the
// node. Reads
//   params[0].x  how far the jaw hangs open, in radians
// and hands the fragment shader (up, along, around, mouth) of the head in out_color, around
// measured across the head in turns of the body.

#define MATERIAL_VERTEX
#include "material.glsl"

const float RADIUS = 0.45;
const vec3 SIZE = vec3(1.3, 0.8, 1.9) * RADIUS;
// the jaw's hinge, (y, z)
const vec2 HINGE = vec2(0.8 * SIZE.y, -0.45);

void main() {
    Material m = node_material();
    float jaw = m.params[0].x;
    vec3 p = normalize(in_position);
    float snout = clamp(-p.z, 0.0, 1.0);
    vec3 size = SIZE * vec3(1.0 - 0.4 * snout * snout, (1.0 - 0.25 * snout) * (p.y > 0.0 ? 1.0 : 0.8), 1.0);
    vec3 position = p * size + vec3(0.0, HINGE.x, -0.55 * SIZE.z);
    vec3 normal = normalize(p / size);

    float angle = jaw * step(p.y, -0.001) * (1.0 - smoothstep(HINGE.y - 0.1, HINGE.y + 0.2, position.z));
    mat2 hang = mat2(cos(angle), -sin(angle), sin(angle), cos(angle));
    position = vec3(position.x, HINGE + hang * (position.yz - HINGE));
    normal = vec3(normal.x, hang * normal.yz);

    float mouth = step(abs(p.y), 0.001) * step(position.z, HINGE.y) * (1.0 + 8.0 * jaw);
    material_vertex(position, normal);
    out_color = vec4(p.y, position.z, position.x / (6.2831853 * RADIUS), mouth);
}
