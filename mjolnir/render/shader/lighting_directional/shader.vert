#version 450

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 3) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 4) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 5) const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec3 a_position;

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
} camera_buffer;

layout(push_constant) uniform PushConstant {
    mat4  shadow_view_projection;
    vec4  light_color;
    vec3  direction;
    uint  shadow_map_idx;
    uint  scene_camera_idx;
    uint  position_texture_index;
    uint  normal_texture_index;
    uint  albedo_texture_index;
    uint  metallic_texture_index;
};

void main() {
    if (scene_camera_idx >= camera_buffer.cameras.length()) {
        gl_Position = vec4(0.0);
        return;
    }

    // Directional lights use fullscreen triangle mesh directly in NDC
    gl_Position = vec4(a_position, 1.0);
}
