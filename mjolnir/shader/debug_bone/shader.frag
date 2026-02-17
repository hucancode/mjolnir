#version 450

// Input from vertex shader
layout(location = 0) in vec4 inColor;

// Output color
layout(location = 0) out vec4 outColor;

void main() {
    // Make point sprites circular (discard fragments outside circle)
    vec2 coord = gl_PointCoord * 2.0 - 1.0;
    float dist = dot(coord, coord);
    if (dist > 1.0) {
        discard;
    }

    // Simple lighting effect (darker edges)
    float edge_falloff = 1.0 - sqrt(dist);
    vec3 lit_color = inColor.rgb * (0.7 + 0.3 * edge_falloff);

    outColor = vec4(lit_color, inColor.a);
}
