#version 450

const float PI = 3.14159265359;
layout(location = 0) in vec3 a_position; // Vertex position for light volume geometry

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9]; // Align to 192-byte
};

// Bindless camera buffer (set 0, binding 0)
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

layout(push_constant) uniform LightPushConstant {
    uint scene_camera_idx;
    uint light_camera_idx;
    uint shadow_map_id;
    uint light_kind;
    vec3 light_color;
    float light_angle;
    vec3 light_position;
    float light_radius;
    vec3 light_direction;
    uint light_cast_shadow;
    uint gbuffer_position_index;
    uint gbuffer_normal_index;
    uint gbuffer_albedo_index;
    uint gbuffer_metallic_index;
    uint gbuffer_emissive_index;
    uint gbuffer_depth_index;
    uint input_image_index;
} push;

const uint POINT_LIGHT = 0;
const uint DIRECTIONAL_LIGHT = 1;
const uint SPOT_LIGHT = 2;

void main() {
    Camera camera = camera_buffer.cameras[push.scene_camera_idx];
    if (push.light_kind == DIRECTIONAL_LIGHT) {
        // For directional lights, use the NDC triangle mesh directly
        gl_Position = vec4(a_position, 1.0);
    } else {
        vec3 world_position;
        if (push.light_kind == POINT_LIGHT) {
            // Scale unit sphere by light radius and translate to light position
            world_position = push.light_position + a_position * push.light_radius;
        } else if (push.light_kind == SPOT_LIGHT) {
            // Standard cone mesh: height=1 (Y+), base radius=1 (XZ)
            float tana = tan(min(push.light_angle*0.5, PI*0.45));
            float y_scale = push.light_radius;
            float xz_scale = push.light_radius * tana * 2;
            vec3 scaled_pos = vec3(a_position.x * xz_scale, (a_position.y - 0.5) * -y_scale, a_position.z * xz_scale);
            // Orient cone along light_direction
            vec3 up = normalize(push.light_direction);
            vec3 forward = abs(up.y) < 0.9 ? normalize(cross(vec3(0, 1, 0), up)) : vec3(1, 0, 0);
            vec3 right = cross(up, forward);
            mat3 orientation = mat3(right, up, forward);
            world_position = push.light_position + orientation * scaled_pos;
        }
        // Transform world position to clip space using camera view-projection
        gl_Position = camera.projection * camera.view * vec4(world_position, 1.0);
    }
}
