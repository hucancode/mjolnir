#version 450

layout(location = 0) in vec3 a_position; // Vertex position for light volume geometry
layout(location = 0) out vec2 v_uv;

// Camera uniform buffer (set 1, binding 0)
layout(set = 0, binding = 0) uniform CameraUniform {
    mat4 view;
    mat4 projection;
} camera;

layout(push_constant) uniform LightPushConstant {
    mat4 light_view_proj; // 64 bytes
    vec3 light_color;     // 12 bytes
    float light_angle;    // 4 bytes
    vec3 light_position;  // 12 bytes
    float light_radius;   // 4 bytes
    vec3 light_direction; // 12 bytes
    uint light_kind;      // 4 bytes
    vec3 camera_position; // 12 bytes
    uint shadow_map_id;   // 4 bytes
};

const uint POINT_LIGHT = 0;
const uint DIRECTIONAL_LIGHT = 1;
const uint SPOT_LIGHT = 2;

void main() {
    if (light_kind == DIRECTIONAL_LIGHT) {
        // For directional lights, use the NDC triangle mesh directly
        gl_Position = vec4(a_position, 1.0);
    } else {
        vec3 world_position;
        if (light_kind == POINT_LIGHT) {
            // Scale unit sphere by light radius and translate to light position
            world_position = light_position + a_position * light_radius;
        } else if (light_kind == SPOT_LIGHT) {
            // Standard cone mesh: height=1 (Y+), base radius=1 (XZ)
            float tana = tan(light_angle * 0.5);
            float y_scale = light_radius;
            float xz_scale = light_radius * tana;
            vec3 scaled_pos = vec3(a_position.x * xz_scale, (a_position.y - 0.5) * y_scale, a_position.z * xz_scale);
            // Orient cone along light_direction
            vec3 forward = normalize(light_direction);
            vec3 up = abs(forward.y) < 0.9 ? vec3(0, 1, 0) : vec3(1, 0, 0);
            vec3 right = normalize(cross(forward, up));
            up = cross(right, forward);
            mat3 orientation = mat3(right, up, forward);
            world_position = light_position + orientation * scaled_pos;
        }
        // Transform world position to clip space using camera view-projection
        gl_Position = camera.projection * camera.view * vec4(world_position, 1.0);
    }
    v_uv = (gl_Position.xy / gl_Position.w) * 0.5 + 0.5;
}

