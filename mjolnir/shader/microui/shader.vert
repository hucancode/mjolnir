#version 450
layout(binding = 0) uniform Uniforms {
    mat4 projection;
};

layout(location = 0) in vec2 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;

layout(location = 0) out vec4 fragColor;
layout(location = 1) out vec2 fragUv;

void main() {
    fragColor = color;
    fragUv = uv;
    gl_Position = projection * vec4(position, 0.0, 1.0);
}
