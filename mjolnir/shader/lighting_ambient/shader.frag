#version 450
#extension GL_EXT_nonuniform_qualifier : require

const float PI = 3.14159265359;

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 outColor;

const float AMBIENT_STRENGTH = 0.5;

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

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

layout(push_constant) uniform AmbientPushConstant {
    uint camera_index;
    uint environment_index;
    uint brdf_lut_index;
    uint position_texture_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    uint depth_texture_index;
    float environment_max_lod;
    float ibl_intensity;
};

// Convert a direction vector to equirectangular UV coordinates
vec2 dirToEquirectUv(vec3 dir) {
    float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(-dir.y, -1.0, 1.0)) / PI;
    return vec2(u, v);
}

float linearizeDepth(float depth, float near, float far) {
    float z = depth * 2.0 - 1.0;
    return (2.0 * near * far) / (far + near - z * (far - near));
}

void main() {
    Camera camera = camera_buffer.cameras[camera_index];
    vec2 uv = vec2(v_uv.x, v_uv.y);
    vec3 position = texture(sampler2D(textures[position_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz;
    vec3 normal = texture(sampler2D(textures[normal_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz * 2.0 - 1.0;
    vec3 albedo = texture(sampler2D(textures[albedo_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[metallic_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rg;
    float metallic = clamp(mr.r, 0.0, 1.0);
    float roughness = clamp(mr.g, 0.0, 1.0);
    vec3 emissive = texture(sampler2D(textures[emissive_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;
    // Camera position from bindless camera buffer
    vec3 V = normalize(camera.camera_position - position);
    vec3 R = reflect(-V, normal);
    float NdotV = max(dot(normal, V), 0.0);
    // IBL using bindless textures
    vec3 ambient = vec3(0);
    if (environment_max_lod > 0.0 && ibl_intensity > 0.0) {
        vec2 uvN = dirToEquirectUv(normal);
        float diffuseLod = min(6.0, environment_max_lod);
        vec3 diffuseIBL = textureLod(sampler2D(textures[environment_index], samplers[SAMPLER_LINEAR_REPEAT]), uvN, environment_max_lod).rgb * albedo * ibl_intensity;
        vec2 uvR = dirToEquirectUv(R);
        float specularLod = roughness * environment_max_lod;
        vec3 prefilteredColor = textureLod(sampler2D(textures[environment_index], samplers[SAMPLER_LINEAR_REPEAT]), uvR, specularLod).rgb * ibl_intensity;
        vec2 brdfSample = texture(sampler2D(textures[brdf_lut_index], samplers[SAMPLER_LINEAR_CLAMP]), vec2(NdotV, roughness)).rg;
        vec3 f_metal_fresnel_ibl = albedo * brdfSample.x + brdfSample.y;
        vec3 f_metal_brdf_ibl = f_metal_fresnel_ibl * prefilteredColor;
        vec3 f_dielectric_fresnel_ibl = vec3(0.04) * brdfSample.x + brdfSample.y;
        vec3 f_dielectric_brdf_ibl = mix(diffuseIBL, prefilteredColor * f_dielectric_fresnel_ibl, f_dielectric_fresnel_ibl);
        ambient = mix(f_dielectric_brdf_ibl, f_metal_brdf_ibl, metallic);
    }
    // Fresnel effect for edge highlighting
    float fresnel_strength = mix(metallic, 0.5 * roughness, 0.5);
    float fresnel = 1.0 - pow(1.0 - NdotV, fresnel_strength);
    vec3 fresnelColor = (albedo + emissive) * fresnel * fresnel_strength;
    vec3 final = albedo * ambient * AMBIENT_STRENGTH
        + fresnelColor
        + emissive;
    outColor = vec4(final, 1.0);
    // outColor = vec4(vec3(0.01), 1);
}
