#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;

layout(location = 0) out vec4 outColor;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
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
    gl_Position = camera.projection * camera.view * vec4(inPosition, 1.0);
    outColor = inColor;
}
