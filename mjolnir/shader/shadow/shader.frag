#version 450

layout(location = 0) in vec3 worldPos;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9]; // Align to 192-byte
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
};

layout(push_constant) uniform PushConstants {
    uint node_id;
    uint camera_index;
};

void main() {
    Camera camera = cameras[camera_index];
    // calculate distance from light center to fragment
    vec3 lightPos = camera.camera_position;
    float distance = length(worldPos - lightPos);
    float near = camera.camera_near;
    float far = camera.camera_far;
    // Write normalized linear distance directly to depth buffer
    gl_FragDepth = clamp((distance - near) / (far - near), 0.0, 1.0);
}
