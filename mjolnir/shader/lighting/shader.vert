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
    vec4 viewport_params;
    vec4 position;
    vec4 frustum_planes[6];
};

struct LightData {
    vec4 color;           // RGB + intensity
    float radius;
    float angle_inner;
    float angle_outer;
    uint type;
    uint node_index;
    uint shadow_map;
    uint camera_index;
    uint cast_shadow;
};

// Bindless camera buffer (set 0, binding 0)
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;
// Lights buffer (set 2, binding 0)
layout(set = 2, binding = 0) readonly buffer LightsBuffer {
    LightData lights[];
} lights_buffer;
// World matrices buffer (set 3, binding 0)
layout(set = 3, binding = 0) readonly buffer WorldMatricesBuffer {
    mat4 world_matrices[];
} world_matrices_buffer;

layout(push_constant) uniform PushConstant {
    uint light_index;
    uint scene_camera_idx;
    uint position_texture_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    uint depth_texture_index;
    uint input_image_index;
};

void main() {
    // Bounds checking to prevent GPU crashes
    if (scene_camera_idx >= camera_buffer.cameras.length()) {
        gl_Position = vec4(0.0); // Invalid position to indicate error
        return;
    }
    if (light_index >= lights_buffer.lights.length()) {
        gl_Position = vec4(0.0); // Invalid position to indicate error
        return;
    }

    Camera camera = camera_buffer.cameras[scene_camera_idx];
    LightData light = lights_buffer.lights[light_index];

    // Additional bounds check for node index
    if (light.node_index >= world_matrices_buffer.world_matrices.length()) {
        gl_Position = vec4(0.0); // Invalid position to indicate error
        return;
    }

    // Get light world matrix to calculate position and direction
    mat4 lightWorldMatrix = world_matrices_buffer.world_matrices[light.node_index];
    vec3 light_position = lightWorldMatrix[3].xyz;
    vec3 light_direction = lightWorldMatrix[2].xyz; // Light forward is -Z direction

    if (light.type == DIRECTIONAL_LIGHT) {
        // For directional lights, use the NDC triangle mesh directly
        gl_Position = vec4(a_position, 1.0);
    } else {
        vec3 world_position;
        if (light.type == POINT_LIGHT) {
            // Scale unit sphere by light radius and translate to light position
            world_position = light_position + a_position * light.radius;
        } else if (light.type == SPOT_LIGHT) {
            // Standard cone mesh: height=1 (Y+), base radius=1 (XZ)
            float tana = tan(min(light.angle_outer, PI*0.45));
            float y_scale = light.radius;
            float xz_scale = light.radius * tana * 2;
            vec3 scaled_pos = vec3(a_position.x * xz_scale, (a_position.y - 0.5) * -y_scale, a_position.z * xz_scale);
            // Orient cone along light_direction (which is already -Z forward)
            vec3 up = normalize(light_direction);
            vec3 forward = abs(up.y) < 0.9 ? normalize(cross(vec3(0, 1, 0), up)) : vec3(1, 0, 0);
            vec3 right = cross(up, forward);
            // Create orientation matrix: right=+X, up=+Y, forward=-Z
            mat3 orientation = mat3(right, up, forward);
            world_position = light_position + orientation * scaled_pos;
        }
        // Transform world position to clip space using camera view-projection
        gl_Position = camera.projection * camera.view * vec4(world_position, 1.0);
    }
}
