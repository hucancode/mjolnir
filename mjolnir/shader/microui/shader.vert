#version 450
layout(push_constant) uniform PushConstants {
    mat4 projection;
};

layout(location = 0) in vec2 position;
layout(location = 1) in vec2 uv;
layout(location = 2) in vec4 color;
layout(location = 3) in uint texture_id;

layout(location = 0) out vec4 fragColor;
layout(location = 1) out vec2 fragUv;
layout(location = 2) flat out uint fragTextureId;

void main() {
    fragColor = color;
    fragUv = uv;
    fragTextureId = texture_id;
    gl_Position = projection * vec4(position, 0.0, 1.0);
}
