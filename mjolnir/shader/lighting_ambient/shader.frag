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
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

layout(push_constant) uniform AmbientPushConstant {
    uint camera_index;
    uint irradiance_index;
    uint prefilter_index;
    uint brdf_lut_index;
    uint position_texture_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    float prefilter_max_lod;
    float ibl_intensity;
};

// Fresnel-Schlick with roughness term (Sebastien Lagarde).
vec3 fresnel_schlick_roughness(float cos_theta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0)
        * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

void main() {
    Camera camera = camera_buffer.cameras[camera_index];
    vec2 uv = v_uv;
    vec3 position = texture(sampler2D(textures[position_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz;
    // Background pixels (no geometry) get cleared to black; skybox pass fills
    // them later when enabled. Without this, junk normals would sample the
    // cubemaps and produce flashing colors as the camera rotates.
    if (dot(position, position) < 1e-6) {
        discard;
    }
    vec3 normal = texture(sampler2D(textures[normal_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz * 2.0 - 1.0;
    vec3 albedo = texture(sampler2D(textures[albedo_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[metallic_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rg;
    float metallic = mr.r;
    float roughness = mr.g;
    vec3 emissive = texture(sampler2D(textures[emissive_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;

    vec3 V = normalize(camera.position.xyz - position);
    vec3 R = reflect(-V, normal);
    float NdotV = max(dot(normal, V), 0.0);

    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 F = fresnel_schlick_roughness(NdotV, F0, roughness);

    vec3 ambient = vec3(0.0);
    if (ibl_intensity > 0.0 && prefilter_max_lod > 0.0) {
        // Diffuse term: irradiance cubemap, energy-conserved (kD = (1 - F) * (1 - metallic)).
        vec3 irradiance = texture(samplerCube(cube_textures[irradiance_index], samplers[SAMPLER_LINEAR_CLAMP]), normal).rgb;
        vec3 diffuse = irradiance * albedo;
        vec3 kD = (vec3(1.0) - F) * (1.0 - metallic);

        // Specular term: split-sum approximation.
        // prefilteredColor encodes the GGX-importance-sampled lobe per roughness.
        vec3 prefiltered = textureLod(
            samplerCube(cube_textures[prefilter_index], samplers[SAMPLER_LINEAR_CLAMP]),
            R,
            roughness * prefilter_max_lod
        ).rgb;
        vec2 brdf = texture(
            sampler2D(textures[brdf_lut_index], samplers[SAMPLER_LINEAR_CLAMP]),
            vec2(NdotV, roughness)
        ).rg;
        vec3 specular = prefiltered * (F * brdf.x + brdf.y);

        ambient = (kD * diffuse + specular) * ibl_intensity;
    }

    outColor = vec4(ambient + emissive, 1.0);
}
