#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec4 inColor;

// Output to fragment shader
layout(location = 0) out flat vec4 outColor;
layout(location = 1) out flat uint outColorMode;

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

// Push constant budget: 128 bytes
layout(push_constant) uniform PushConstants {
    mat4 world;            // 64 bytes
    uint camera_index;     // 4
    float height_offset;   // 4 - Raise navmesh slightly above ground
    float alpha;           // 4 - Transparency control
    uint color_mode;       // 4 - 0=area_colors, 1=uniform, 2=height_based
};

void main() {
    // Get camera from bindless buffer
    Camera camera = camera_buffer.cameras[camera_index];

    // Apply height offset to keep navmesh visible above ground
    vec3 position = inPosition;
    position.y += height_offset;

    // Transform to world space then camera space
    vec4 worldPos = world * vec4(position, 1.0);
    gl_Position = camera.projection * camera.view * worldPos;

    // Pass color to fragment shader
    outColor = inColor;
    outColor.a = alpha;
    outColorMode = color_mode;
}
