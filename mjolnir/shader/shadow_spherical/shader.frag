#version 450

layout(location = 0) in vec3 fragWorldPos;

struct Camera {
    mat4 view;
    mat4 projection;
    vec4 viewport_params;
    vec4 position;
    vec4 frustum_planes[6];
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
};

layout(push_constant) uniform PushConstants {
    uint camera_index;
};

void main() {
    Camera camera = cameras[camera_index];
    vec3 lightPos = camera.position.xyz;
    float linearDepth = length(fragWorldPos - lightPos);
    float near = camera.viewport_params.z;
    float far = camera.viewport_params.w;
    // Linear depth mapping: [near, far] -> [0, 1]
    // Provides uniform precision across entire light radius
    gl_FragDepth = (linearDepth - near) / (far - near);
    gl_FragDepth = clamp(gl_FragDepth, 0.0, 1.0);
}
