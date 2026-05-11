#version 450
#extension GL_EXT_nonuniform_qualifier : require

const float PI = 3.14159265359;

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 3) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 4) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 5) const uint SAMPLER_LINEAR_REPEAT = 3u;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 outColor;

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

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform SkyboxPushConstant {
    uint camera_index;
    uint environment_index;
    uint position_texture_index;
    float intensity;
    float lod;
};

vec2 dirToEquirectUv(vec3 dir) {
    float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(-dir.y, -1.0, 1.0)) / PI;
    return vec2(u, v);
}

void main() {
    vec3 position = texture(sampler2D(textures[position_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), v_uv).xyz;
    if (dot(position, position) > 1e-6) {
        discard;
    }
    Camera camera = camera_buffer.cameras[camera_index];
    mat4 inv_vp = inverse(camera.projection * camera.view);
    vec2 ndc = v_uv * 2.0 - 1.0;
    vec4 world_far = inv_vp * vec4(ndc, 1.0, 1.0);
    vec3 dir = normalize(world_far.xyz / world_far.w - camera.position.xyz);
    vec2 uv = dirToEquirectUv(dir);
    vec3 sky = textureLod(sampler2D(textures[environment_index], samplers[SAMPLER_LINEAR_REPEAT]), uv, lod).rgb * intensity;
    outColor = vec4(sky, 1.0);
}
