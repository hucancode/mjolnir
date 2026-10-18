#version 450
// Carves a snake out of a sphere as long as it: the sphere's rings run head to tail along the
// spine, which retraces the path the head travelled and slithers with the distance travelled. Reads
//   params[0]  x the distance travelled, y the speed, z the length and radius (two halves)
//   params[0].w, params[1]  how far the body turns over each of its stretches, 3 bytes a float
// and hands the fragment shader (up, along, side) of the body in out_color.

#define MATERIAL_VERTEX
#include "material.glsl"

const float WAVES = 2.0;

float girth(float t, float radius) {
    float head = 1.0 + 0.4 * exp(-pow((t - 0.06) / 0.05, 2.0));
    return radius * head * pow(sin(3.14159265 * t), 0.35) * (1.0 - 0.6 * t);
}

const int SAMPLES = 15;
const float TURN_SCALE = 0.5 * 6.0 / 15.0 / 127.0; // radians per byte: MAX_CURVATURE * len / SAMPLES / 127

// The direction the body runs `s` down it, as the angle it has turned from the head's: the head's
// heading minus the one it had then. It turns steadily over each of the SAMPLES stretches.
float turned(float[SAMPLES] k, float s, float len) {
    float f = clamp(s / len, 0.0, 1.0) * float(SAMPLES);
    int i = min(int(f), SAMPLES - 1);
    float angle = 0.0;
    for (int j = 0; j < i; j++) angle += k[j];
    return (angle + k[i] * (f - float(i))) * TURN_SCALE;
}

// The point `s` down the body, the head at -len / 2: the path the head travelled. Also gives the
// direction the body runs there.
vec3 spine(float[SAMPLES] k, float s, float len, out vec3 along) {
    const int STEPS = 32;
    float h = s / float(STEPS);
    vec2 p = vec2(0.0);
    for (int i = 0; i < STEPS; i++) {
        float angle = turned(k, (float(i) + 0.5) * h, len);
        p += h * vec2(-sin(angle), cos(angle));
    }
    float angle = turned(k, s, len);
    along = vec3(-sin(angle), 0.0, cos(angle));
    return vec3(p.x, 0.0, p.y - 0.5 * len);
}

// How far the body swings aside at `t`: waves running down it as it travels, wider at speed.
float sway(float t, vec4 motion) {
    float amplitude = 0.4 * smoothstep(0.0, 0.3, t) * mix(0.15, 1.0, clamp(motion.y / 3.0, 0.0, 1.0));
    return sin(t * WAVES * 6.2831853 - motion.x * 2.5) * amplitude;
}

void main() {
    Material m = node_material();
    vec4 motion = m.params[0];
    vec2 size = unpackHalf2x16(floatBitsToUint(motion.z));
    float len = size.x;
    float radius = size.y;
    float packed[5] = float[5](motion.w, m.params[1].x, m.params[1].y, m.params[1].z, m.params[1].w);
    float k[SAMPLES];
    for (int i = 0; i < SAMPLES; i++) {
        int b = int((floatBitsToUint(packed[i / 3]) >> (8u * uint(i % 3))) & 255u);
        k[i] = float(b > 127 ? b - 256 : b);
    }
    float t = clamp(in_uv.y, 0.001, 0.999);
    vec2 around = normalize(in_position.xz + vec2(1e-5, 0.0));

    vec3 forward;
    vec3 center = spine(k, t * len, len, forward);
    vec3 side = normalize(vec3(forward.z, 0.0, -forward.x));
    vec3 normal = normalize(side * around.x + vec3(0.0, around.y, 0.0));
    float r = girth(t, radius);
    vec3 position = center + side * (sway(t, motion) + around.x * r);
    position.y = r * 0.65 + around.y * r * (around.y < 0.0 ? 0.65 : 1.0);

    material_vertex(position, normal);
    out_color = vec4(around.y, t, around.x, 1.0);
}
