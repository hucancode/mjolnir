#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;

layout(push_constant) uniform BlurParams {
    float radius;
} params;

const int MAX_RADIUS = 16;

void main() {
    vec2 texel_size = 1.0 / vec2(textureSize(u_input_image, 0));
    vec4 color = vec4(0.0);
    float total = 0.0;

    int radius = int(params.radius);
    radius = clamp(radius, 1, MAX_RADIUS);

    for (int i = -MAX_RADIUS; i <= MAX_RADIUS; ++i) {
        if (abs(i) > radius) continue;
        float weight = exp(-0.5 * (float(i) * float(i)) / (params.radius * params.radius));
        vec2 offset = vec2(float(i), 0.0) * texel_size; // horizontal blur
        color += texture(u_input_image, v_uv + offset) * weight;
        total += weight;
    }
    out_color = color / total;
}
