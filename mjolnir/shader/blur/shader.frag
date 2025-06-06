#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;

layout(push_constant) uniform BlurParams {
    float radius;
    float padding[3];
};

const float MAX_RADIUS = 16.0;

void main() {
    vec2 texel_size = 1.0 / vec2(textureSize(u_input_image, 0));
    vec4 color = vec4(0.0);
    float total = 0.0;

    float radius = clamp(radius, 1.0, MAX_RADIUS);

    for (float i = -MAX_RADIUS; i <= MAX_RADIUS; i+=1.0) {
        if (abs(i) > radius) continue;
        float weight = exp(-0.5 * (i * i) / (radius * radius));
        vec2 offset = vec2(i, 0.0) * texel_size; // horizontal blur
        color += texture(u_input_image, v_uv + offset) * weight;
        total += weight;
    }
    out_color = color / total;
}
