#version 450

layout(location = 0) in vec3 fragWorldPos;

struct ShadowData {
    mat4 view;
    mat4 projection;
    vec3 position;
    float near;
    vec3 direction;
    float far;
    vec4 frustum_planes[6];
};

layout(set = 0, binding = 0) readonly buffer ShadowBuffer {
    ShadowData shadows[];
};

layout(push_constant) uniform PushConstants {
    uint shadow_index;
};

void main() {
    ShadowData shadow = shadows[shadow_index];
    vec3 lightPos = shadow.position.xyz;
    float linearDepth = length(fragWorldPos - lightPos);
    // Linear depth mapping: [near, far] -> [0, 1]
    // Provides uniform precision across entire light radius
    gl_FragDepth = (linearDepth - shadow.near) / (shadow.far - shadow.near);
    gl_FragDepth = clamp(gl_FragDepth, 0.0, 1.0);
}
