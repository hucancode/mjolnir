#version 450

layout(location = 0) in vec3 fragWorldPos;

layout(push_constant) uniform PushConstants {
    mat4  projection;      // 64 bytes
    vec3  light_position;  // 12 bytes (aligned to 16)
    float near_plane;      // 4 bytes
    float far_plane;       // 4 bytes
};

void main() {
    vec3 lightPos = light_position;
    float linearDepth = length(fragWorldPos - lightPos);
    // Linear depth mapping: [near, far] -> [0, 1]
    // Provides uniform precision across entire light radius
    gl_FragDepth = (linearDepth - near_plane) / (far_plane - near_plane);
    gl_FragDepth = clamp(gl_FragDepth, 0.0, 1.0);
}
