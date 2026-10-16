#version 450
// A user post-process shader: darkens toward `color` away from the screen center.

#define POST_PARAMS vec3 color; float radius; float softness; float strength;
#include "post.glsl"

void main() {
    vec4 scene = post_input(v_uv);
    float d = length(v_uv - 0.5);
    float vignette = 1.0 - smoothstep(radius - softness, radius, d);
    out_color = vec4(mix(color, scene.rgb, mix(1.0, vignette, strength)), 1.0);
}
