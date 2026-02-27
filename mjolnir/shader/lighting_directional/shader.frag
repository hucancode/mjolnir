#version 450
#extension GL_EXT_nonuniform_qualifier : require

const float PI = 3.14159265359;

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 3) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 4) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 5) const uint SAMPLER_LINEAR_REPEAT = 3u;

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

float calculateShadow(vec3 fragPos, vec3 normal) {
    if (shadow_map_idx == 0xFFFFFFFFu || shadow_map_idx >= MAX_TEXTURES) {
        return 1.0;
    }

    vec4 lightSpacePos = shadow_view_projection * vec4(fragPos, 1.0);
    vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
    shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
    shadowCoord.y = 1.0 - shadowCoord.y;

    if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
        shadowCoord.y < 0.0 || shadowCoord.y > 1.0) {
        return 1.0;
    }

    shadowCoord.z = clamp(shadowCoord.z, 0.0, 1.0);

    vec3 lightDir = normalize(-direction);
    float cosTheta = clamp(dot(normal, lightDir), 0.0, 1.0);
    float bias = 0.005 * tan(acos(cosTheta));
    bias = clamp(bias, 0.001, 0.01);

    float shadowDepth = texture(sampler2D(textures[shadow_map_idx], samplers[SAMPLER_LINEAR_CLAMP]), shadowCoord.xy).r;
    return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
}

vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 light_col = light_color.rgb * light_color.a;

    // Directional light direction (negate to get direction TO light)
    vec3 L = normalize(-direction);
    vec3 H = normalize(V + L);

    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.01);
    float NdotH = max(dot(N, H), 0.0);

    // Cook-Torrance BRDF
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float denom = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
    denom = max(denom, 0.001);
    float NDF = alpha2 / (PI * denom * denom);

    float k = pow(roughness + 1.0, 2.0) / 8.0;
    float G = NdotL / (NdotL * (1.0 - k) + k);
    G *= NdotV / (NdotV * (1.0 - k) + k);

    vec3 F = F0 + (1.0 - F0) * pow(1.0 - max(dot(H, V), 0.0), 5.0);
    vec3 spec = NDF * G * F / (4.0 * NdotV * NdotL + 0.01);

    vec3 kS = clamp(F, 0.0, 1.0);
    vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);

    return (kD * albedo / PI + spec) * light_col * NdotL;
}

void main() {
    if (scene_camera_idx >= camera_buffer.cameras.length()) {
        outColor = vec4(0.0, 1.0, 0.0, 1.0);
        return;
    }

    Camera camera = camera_buffer.cameras[scene_camera_idx];
    vec2 uv = gl_FragCoord.xy / camera.viewport_extent;

    vec3 fragPos = texture(sampler2D(textures[position_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).xyz;
    vec3 normal = normalize(texture(sampler2D(textures[normal_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).xyz * 2.0 - 1.0);
    vec3 albedo = texture(sampler2D(textures[albedo_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[metallic_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).rg;

    float metallic = clamp(mr.r, 0.0, 1.0);
    float roughness = clamp(mr.g, 0.08, 1.0);

    vec3 V = normalize(camera.position.xyz - fragPos);
    float shadowFactor = calculateShadow(fragPos, normal);
    vec3 direct = brdf(normal, V, albedo, roughness, metallic);

    outColor = vec4(direct * shadowFactor, 1.0);
}
