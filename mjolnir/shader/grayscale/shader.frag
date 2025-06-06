#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;

layout(push_constant) uniform GrayscaleParams {
    vec3 weights;
    float strength;
} params;

void main() {
    vec4 color = texture(u_input_image, v_uv);
    float gray = dot(color.rgb, params.weights);
    out_color = mix(color, vec4(gray, gray, gray, color.a), params.strength);
}
