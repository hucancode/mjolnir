#version 450

const float PI = 3.14159265359;

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;
layout(constant_id = 0) const uint LIGHT_TYPE = 0u;

const uint LIGHT_POINT = 0u;
const uint LIGHT_SPOT = 1u;
const uint LIGHT_DIRECTIONAL = 2u;
const uint LIGHT_AMBIENT = 3u;

layout(location = 0) in vec3 a_position;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    mat4 inv_view_projection;
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

struct Light {
    vec4 color;
    vec3 position;
    float radius;
    vec3 direction;
    float angle_inner;
    float angle_outer;
    uint shadow_map; // view index of the first shadow face
    float shadow_texel; // world size of a shadow texel; per unit of view depth for point and spot
    uint _pad0;
};

layout(set = 0, binding = 10) readonly buffer LightBuffer {
    Light lights[];
};

layout(push_constant) uniform PushConstant {
    uint camera_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    uint depth_texture_index;
    uint irradiance_index;
    uint prefilter_index;
    uint brdf_lut_index;
    uint environment_index;
    float skybox_intensity;
    float skybox_blur;
};

layout(location = 0) flat out uint v_light;

void main() {
    v_light = gl_InstanceIndex;
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL || LIGHT_TYPE == LIGHT_AMBIENT) {
        // the volume is a clip-space triangle covering the screen on the far
        // plane: directional lights depth-test it to skip the background
        gl_Position = vec4(a_position.xy, 1.0, 1.0);
        return;
    }
    Light light = lights[gl_InstanceIndex];
    Camera camera = camera_buffer.cameras[camera_index];
    vec3 world_position;
    if (LIGHT_TYPE == LIGHT_POINT) {
        // Unit sphere scaled to the light radius
        world_position = light.position + a_position * light.radius;
    } else {
        // Unit cone (height 1 along +Y, base radius 1) flipped so its tip sits
        // at the light and its base covers the outer angle at `radius`
        float tana = tan(min(light.angle_outer, PI * 0.45));
        float xz_scale = light.radius * tana * 2.0;
        vec3 scaled_pos = vec3(
            a_position.x * xz_scale,
            (a_position.y - 0.5) * -light.radius,
            a_position.z * xz_scale
        );
        vec3 up = light.direction;
        vec3 forward = abs(up.y) < 0.9 ? normalize(cross(vec3(0, 1, 0), up)) : vec3(1, 0, 0);
        vec3 right = cross(up, forward);
        world_position = light.position + mat3(right, up, forward) * scaled_pos;
    }
    gl_Position = camera.projection * camera.view * vec4(world_position, 1.0);
}
