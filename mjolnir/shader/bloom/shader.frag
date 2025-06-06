#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;

layout(push_constant) uniform BloomParams {
    float threshold;
    float intensity;
    float radius;
    float padding;
} params;

const int MAX_RADIUS = 8;

vec4 blur_bright(sampler2D img, vec2 uv, float radius, float threshold) {
    vec2 texel = 1.0 / vec2(textureSize(img, 0));
    vec4 color = vec4(0.0);
    float total = 0.0;
    int r = int(radius);
    for (int i = -MAX_RADIUS; i <= MAX_RADIUS; ++i) {
        if (abs(i) > r) continue;
        float weight = exp(-0.5 * i * i / radius / radius);
        vec4 sample_pixel = texture(img, uv + vec2(i, 0.0) * texel);
        float brightness = max(max(sample_pixel.r, sample_pixel.g), sample_pixel.b);
        if (brightness > threshold)
            color += sample_pixel * weight;
        total += weight;
    }
    color /= total;
    return color;
}

void main() {
    vec4 orig = texture(u_input_image, v_uv);
    vec4 bloom = blur_bright(u_input_image, v_uv, params.radius, params.threshold) * params.intensity;
    out_color = clamp(orig + bloom, 0.0, 1.0);
}
