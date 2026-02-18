#version 450

// Per-instance vertex attributes
layout(location = 0) in vec3 inPosition;  // Bone world position
layout(location = 1) in vec4 inColor;      // Hierarchical color
layout(location = 2) in float inScale;     // Bone visualization scale

// Output to fragment shader
layout(location = 0) out vec4 outColor;

out gl_PerVertex {
    vec4 gl_Position;
    float gl_PointSize;
};

// Camera structure
struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    vec4 frustum_planes[6];
};

// Bindless camera buffer set = 0
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

layout(push_constant) uniform PushConstants {
    uint camera_index;
} push;

void main() {
    Camera camera = camera_buffer.cameras[push.camera_index];

    // Pass color to fragment shader
    outColor = inColor;

    // Transform position to clip space
    gl_Position = camera.projection * camera.view * vec4(inPosition, 1.0);

    // Calculate point size based on scale and distance
    // Bones closer to camera appear larger
    float dist = max(length(camera.position.xyz - inPosition), 0.1);
    gl_PointSize = clamp((inScale * 50.0) / dist, 5.0, 50.0);
}
