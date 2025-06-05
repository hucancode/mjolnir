#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;

layout(push_constant) uniform ToneMapParams {
    float exposure;
    float gamma;
} params;

void main() {
    vec3 color = texture(u_input_image, v_uv).rgb;
    // Simple Reinhard tonemapping
    color = vec3(1.0) - exp(-color * params.exposure);
    color = pow(color, vec3(1.0 / params.gamma));
    out_color = vec4(color, 1.0);
}