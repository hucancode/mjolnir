#version 450

const float PI = 3.14159265359;

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 3) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 4) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 5) const uint SAMPLER_LINEAR_REPEAT = 3u;
layout(constant_id = 6) const uint LIGHT_TYPE = 0u;

const uint LIGHT_POINT = 0u;
const uint LIGHT_SPOT = 1u;
const uint LIGHT_DIRECTIONAL = 2u;

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

// Indices are packed two per uint, low 16 bits first.
layout(push_constant) uniform PushConstant {
    mat4  shadow_view_projection;
    vec4  light_color;
    vec3  position;
    float angle_inner;
    vec3  direction;
    float radius;
    float angle_outer;
    uint  shadow_and_camera_indices;
    uint  position_and_normal_indices;
    uint  albedo_and_metallic_indices;
};

void main() {
    uint scene_camera_idx = shadow_and_camera_indices >> 16u;
    if (scene_camera_idx >= camera_buffer.cameras.length()) {
        gl_Position = vec4(0.0);
        return;
    }
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) {
        // Full-screen triangle; a_position is unused
        vec2 p = vec2(gl_VertexIndex == 1 ? 3.0 : -1.0, gl_VertexIndex == 2 ? 3.0 : -1.0);
        gl_Position = vec4(p, 0.0, 1.0);
        return;
    }
    Camera camera = camera_buffer.cameras[scene_camera_idx];
    vec3 world_position;
    if (LIGHT_TYPE == LIGHT_POINT) {
        // Unit sphere scaled to the light radius
        world_position = position + a_position * radius;
    } else {
        // Unit cone (height 1 along +Y, base radius 1) flipped so its tip sits
        // at the light and its base covers the outer angle at `radius`
        float tana = tan(min(angle_outer, PI * 0.45));
        float xz_scale = radius * tana * 2.0;
        vec3 scaled_pos = vec3(
            a_position.x * xz_scale,
            (a_position.y - 0.5) * -radius,
            a_position.z * xz_scale
        );
        vec3 up = normalize(direction);
        vec3 forward = abs(up.y) < 0.9 ? normalize(cross(vec3(0, 1, 0), up)) : vec3(1, 0, 0);
        vec3 right = cross(up, forward);
        world_position = position + mat3(right, up, forward) * scaled_pos;
    }
    gl_Position = camera.projection * camera.view * vec4(world_position, 1.0);
}
