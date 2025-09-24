#version 450

layout(location = 0) in vec3 worldPos;

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
    // calculate distance from light center to fragment
    vec3 lightPos = camera.position.xyz;
    float distance = length(worldPos - lightPos);
    float near = camera.viewport_params.z;
    float far = camera.viewport_params.w;
    // Write normalized linear distance directly to depth buffer
    gl_FragDepth = clamp((distance - near) / (far - near), 0.0, 1.0);
}
