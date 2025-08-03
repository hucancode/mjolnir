#version 450

layout(location = 0) in vec3 inPosition;
layout(location = 1) in vec3 inNormal;

// Output to fragment shader
layout(location = 0) out vec3 outNormal;
layout(location = 1) out vec3 outWorldPos;
layout(location = 2) out flat vec4 outDebugColor;

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

// Push constant budget: 128 bytes
layout(push_constant) uniform PushConstants {
    mat4 world;            // 64 bytes
    uint camera_index;     // 4
    float height_offset;   // 4 - Raise navmesh slightly above ground
    float line_width;      // 4 - Wireframe line width
    uint debug_mode;       // 4 - 0=wireframe, 1=normals, 2=connectivity
    vec3 debug_color;      // 12 - Base debug color
    float padding[8];      // 32 (pad to 128)
};

void main() {
    // Get camera from bindless buffer
    Camera camera = camera_buffer.cameras[camera_index];

    // Apply height offset to keep navmesh visible above ground
    vec3 position = inPosition;
    position.y += height_offset;

    // Transform to world space
    vec4 worldPos = world * vec4(position, 1.0);
    outWorldPos = worldPos.xyz;

    // Transform normal to world space
    mat3 normalMatrix = mat3(world);
    outNormal = normalize(normalMatrix * inNormal);

    // Calculate debug color based on mode
    if (debug_mode == 1) {
        // Normal visualization mode - encode normals as colors
        outDebugColor = vec4(outNormal * 0.5 + 0.5, 1.0);
    } else if (debug_mode == 2) {
        // Connectivity mode - use vertex position as color basis
        outDebugColor = vec4(sin(position.x), cos(position.z), sin(position.x + position.z), 1.0);
    } else {
        // Default wireframe mode
        outDebugColor = vec4(debug_color, 1.0);
    }

    gl_Position = camera.projection * camera.view * worldPos;
}
