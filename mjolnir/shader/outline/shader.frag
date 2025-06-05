#version 450

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 out_color;

layout(set = 0, binding = 0) uniform sampler2D u_input_image;

layout(push_constant) uniform OutlineParams {
    vec3 color;
    float line_width;
} params;

void main() {
    vec2 texel = 1.0 / vec2(textureSize(u_input_image, 0));
    float edge = 0.0;

    // Simple edge detection using luminance difference with neighbors
    float center = dot(texture(u_input_image, v_uv).rgb, vec3(0.299, 0.587, 0.114));
    float threshold = 0.2;

    float left   = dot(texture(u_input_image, v_uv + vec2(-texel.x * params.line_width, 0)).rgb, vec3(0.299, 0.587, 0.114));
    float right  = dot(texture(u_input_image, v_uv + vec2( texel.x * params.line_width, 0)).rgb, vec3(0.299, 0.587, 0.114));
    float up     = dot(texture(u_input_image, v_uv + vec2(0,  texel.y * params.line_width)).rgb, vec3(0.299, 0.587, 0.114));
    float down   = dot(texture(u_input_image, v_uv + vec2(0, -texel.y * params.line_width)).rgb, vec3(0.299, 0.587, 0.114));

    if (abs(center - left) > threshold ||
        abs(center - right) > threshold ||
        abs(center - up) > threshold ||
        abs(center - down) > threshold) {
        edge = 1.0;
    }

    vec3 base = texture(u_input_image, v_uv).rgb;
    out_color = vec4(mix(base, params.color, edge), 1.0);
}