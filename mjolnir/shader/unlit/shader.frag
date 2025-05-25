#version 450

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool HAS_ALBEDO_TEXTURE = false;

layout(set = 0, binding = 0) uniform SceneUniforms {
    mat4 view;
    mat4 proj;
    float time;
};

layout(set = 1, binding = 0) uniform sampler2D albedoSampler;

layout(set = 1, binding = 5) uniform MaterialFallbacks {
    vec4 albedoValue;
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec2 uv;
layout(location = 0) out vec4 outColor;

void main() {
    outColor = HAS_ALBEDO_TEXTURE ? texture(albedoSampler, uv) : albedoValue;
}
