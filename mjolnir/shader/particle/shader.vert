#version 450

layout (location = 0) in vec4 inPosition;
layout (location = 1) in vec4 inColor;
layout (location = 2) in float inSize;
layout (location = 3) in uint inTextureIndex;

layout (location = 0) out vec4 outColor;
layout (location = 1) out flat uint outTextureIndex;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_PointSize;
};

// Camera structure
struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9]; // Align to 192-byte
};

// Bindless camera buffer set = 0
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

layout(push_constant) uniform ParticlePushConstants {
    uint camera_index;
} push;

void main() {
    Camera camera = camera_buffer.cameras[push.camera_index];
    vec4 cameraPosition = -inverse(camera.view)[3];
    outColor = inColor;
    outTextureIndex = inTextureIndex;
    gl_Position = camera.projection * camera.view * inPosition;
    float dist = clamp(length((cameraPosition - inPosition).xyz), 1.0, 20.0);
    gl_PointSize = clamp(inSize / dist, 10.0, 100.0);
}
