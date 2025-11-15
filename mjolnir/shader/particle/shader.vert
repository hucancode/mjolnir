#version 450

layout (location = 0) in vec3 inPosition;
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
    vec4 viewport_params;
    vec4 position;
    vec4 frustum_planes[6];
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
    outColor = inColor;
    outTextureIndex = inTextureIndex;
    gl_Position = camera.projection * camera.view * vec4(inPosition, 1.0);
    float dist = clamp(length(camera.position.xyz - inPosition), 1.0, 20.0);
    gl_PointSize = clamp(inSize / dist, 10.0, 100.0);
}
