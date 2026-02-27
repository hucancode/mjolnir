#version 450

const float PI = 3.14159265359;

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint MAX_SAMPLERS = 1u;
layout(constant_id = 3) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 4) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 5) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 6) const uint SAMPLER_LINEAR_REPEAT = 3u;
layout(constant_id = 7) const uint POINT_LIGHT = 0u;
layout(constant_id = 8) const uint DIRECTIONAL_LIGHT = 1u;
layout(constant_id = 9) const uint SPOT_LIGHT = 2u;

layout(location = 0) in vec3 a_position; // Vertex position for light volume geometry

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    vec4 frustum_planes[6];
};

// Bindless camera buffer (set 0, binding 0)
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

layout(push_constant) uniform PushConstant {
    vec4  light_color;       // 16 bytes
    vec3  position;          // 12 bytes
    float radius;            // 4 bytes
    vec3  direction;         // 12 bytes
    float angle_inner;       // 4 bytes
    float angle_outer;       // 4 bytes
    uint  light_type;        // 4 bytes
    uint  shadow_map_idx;    // 4 bytes
    uint  scene_camera_idx;  // 4 bytes
    mat4  shadow_view_projection;  // 64 bytes
    float shadow_near;             // 4 bytes
    float shadow_far;              // 4 bytes
    uint position_texture_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    uint input_image_index;
};

void main() {
    // Bounds checking to prevent GPU crashes
    if (scene_camera_idx >= camera_buffer.cameras.length()) {
        gl_Position = vec4(0.0); // Invalid position to indicate error
        return;
    }

    Camera camera = camera_buffer.cameras[scene_camera_idx];

    if (light_type == DIRECTIONAL_LIGHT) {
        // For directional lights, use the NDC triangle mesh directly
        gl_Position = vec4(a_position, 1.0);
    } else {
        vec3 world_position;
        if (light_type == POINT_LIGHT) {
            // Scale unit sphere by light radius and translate to light position
            world_position = position + a_position * radius;
        } else if (light_type == SPOT_LIGHT) {
            // Standard cone mesh: height=1 (Y+), base radius=1 (XZ)
            float tana = tan(min(angle_outer, PI*0.45));
            float y_scale = radius;
            float xz_scale = radius * tana * 2;
            vec3 scaled_pos = vec3(a_position.x * xz_scale, (a_position.y - 0.5) * -y_scale, a_position.z * xz_scale);
            // Orient cone along light_direction (which is already -Z forward)
            vec3 up = normalize(direction);
            vec3 forward = abs(up.y) < 0.9 ? normalize(cross(vec3(0, 1, 0), up)) : vec3(1, 0, 0);
            vec3 right = cross(up, forward);
            // Create orientation matrix: right=+X, up=+Y, forward=-Z
            mat3 orientation = mat3(right, up, forward);
            world_position = position + orientation * scaled_pos;
        }
        // Transform world position to clip space using camera view-projection
        gl_Position = camera.projection * camera.view * vec4(world_position, 1.0);
    }
}
