#version 450

layout(location = 0) in vec3 inPosition;

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
    mat4 transform;
    vec4 color;
    uint camera_index;
    uint style;
};

void main() {
    Camera camera = cameras[camera_index];
    vec4 worldPos = transform * vec4(inPosition, 1.0);
    gl_Position = camera.projection * camera.view * worldPos;
}
