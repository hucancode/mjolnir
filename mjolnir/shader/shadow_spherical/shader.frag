#version 450

layout(location = 0) in vec3 fragWorldPos;

struct SphericalCamera {
    mat4 projection;
    vec4 position; // center.xyz, radius in w
    vec2 near_far;
    vec2 _padding;
};

layout(set = 0, binding = 0) readonly buffer SphericalCameraBuffer {
    SphericalCamera cameras[];
};

layout(push_constant) uniform PushConstants {
    uint camera_index;
};

void main() {
    SphericalCamera camera = cameras[camera_index];
    vec3 lightPos = camera.position.xyz;
    float linearDepth = length(fragWorldPos - lightPos);
    float near = camera.near_far.x;
    float far = camera.near_far.y;
    // Linear depth mapping: [near, far] -> [0, 1]
    // Provides uniform precision across entire light radius
    gl_FragDepth = (linearDepth - near) / (far - near);
    gl_FragDepth = clamp(gl_FragDepth, 0.0, 1.0);
}
