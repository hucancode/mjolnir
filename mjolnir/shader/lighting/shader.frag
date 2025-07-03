#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint MAX_SHADOW_MAPS = 10;
const float PI = 3.14159265359;


layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 outColor;

const float AMBIENT_STRENGTH = 0.2;
const int POINT_LIGHT = 0;
const int DIRECTIONAL_LIGHT = 1;
const int SPOT_LIGHT = 2;

layout(set = 0, binding = 0) uniform sampler2D gbuffer_position;
layout(set = 0, binding = 1) uniform sampler2D gbuffer_normal;
layout(set = 0, binding = 2) uniform sampler2D gbuffer_albedo;
layout(set = 0, binding = 3) uniform sampler2D gbuffer_metallic_roughness;
layout(set = 0, binding = 4) uniform sampler2D gbuffer_emissive;
layout(set = 0, binding = 5) uniform sampler2D shadow_maps[MAX_SHADOW_MAPS];
layout(set = 0, binding = 6) uniform samplerCube cube_shadow_maps[MAX_SHADOW_MAPS];

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform LightPushConstant {
    mat4 light_view;
    mat4 light_proj;
    vec4 light_color;
    vec4 light_position;
    vec4 light_direction;
    vec3 camera_position;
    uint light_kind;
    float light_angle;
    float light_radius;
    uint environment_index;
    uint brdf_lut_index;
    float environment_max_lod;
    float ibl_intensity;
};

// Convert a direction vector to equirectangular UV coordinates
vec2 dirToEquirectUV(vec3 dir) {
    float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(-dir.y, -1.0, 1.0)) / PI;
    return vec2(u, v);
}

float linearizeDepth(float depth, float near, float far) {
    float z = depth * 2.0 - 1.0;
    return (2.0 * near * far) / (far + near - z * (far - near));
}

float calculateShadow(vec3 fragPos, vec3 N) {
    // Point light shadow (light_kind == 0), Directional shadow (light_kind == 1)
    if (light_kind == DIRECTIONAL_LIGHT) {
        // Directional light shadow (existing code)
        vec4 lightSpacePos = light_proj * light_view * vec4(fragPos, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        shadowCoord = shadowCoord * 0.5 + 0.5;
        if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
            shadowCoord.z < 0.0 || shadowCoord.z > 1.0) {
            return 1.0;
        }
        float shadowDepth = texture(shadow_maps[0], shadowCoord.xy).r;
        float bias = max(0.1 * (1.0 - dot(N, normalize(-light_direction.xyz))), 0.05);
        return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
    } else if (light_kind == POINT_LIGHT) {
        // Point light shadow using cubemap
        vec3 lightToFrag = fragPos - light_position.xyz;
        float currentDepth = length(lightToFrag);
        float shadowMapDepth = texture(cube_shadow_maps[0], lightToFrag).r;
        float far_plane = light_radius;
        shadowMapDepth *= far_plane; // Remap [0,1] to [0,far_plane]
        float bias = 0.05;
        // Optionally, add bias based on angle between normal and light direction
        // float bias = max(0.05 * (1.0 - dot(N, normalize(lightToFrag))), 0.01);
        return (currentDepth - bias > shadowMapDepth) ? 0.1 : 1.0;
    }
    return 1.0;
}

vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic, vec3 fragPos) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 Lo = vec3(0.0);
    // Only one light for now (deferred pass is usually per-light or with a light buffer)
    vec3 L = light_kind == 1 ? normalize(-light_direction.xyz) : normalize(light_position.xyz - fragPos);
    vec3 H = normalize(V + L);
    float distance = light_kind == 1 ? 1.0 : length(light_position.xyz - fragPos);
    float attenuation = light_radius;
    if (light_kind != 1) {
        float norm_dist = distance / max(0.01, light_radius);
        attenuation *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
    }
    float NdotL = max(dot(N, L), 0.0);
    // Cook-Torrance BRDF
    float NDF = pow(roughness, 4.0) / (PI * pow((dot(N, H) * dot(N, H)) * (pow(roughness, 4.0) - 1.0) + 1.0, 2.0));
    float k = pow(roughness + 1.0, 2.0) / 8.0;
    float G = NdotL / (NdotL * (1.0 - k) + k);
    G *= max(dot(N, V), 0.0) / (max(dot(N, V), 0.0) * (1.0 - k) + k);
    vec3 F = F0 + (1.0 - F0) * pow(1.0 - max(dot(H, V), 0.0), 5.0);
    vec3 spec = (NDF * G * F) / (4.0 * max(dot(N, V), 0.0) * NdotL + 0.001);
    vec3 kS = F;
    vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);
    Lo += (kD * albedo / PI + spec) * light_color.rgb * NdotL * attenuation;
    return Lo;
}

void main() {
    vec3 position = texture(gbuffer_position, v_uv).xyz;
    vec3 normal = texture(gbuffer_normal, v_uv).xyz * 2.0 - 1.0;
    vec3 albedo = texture(gbuffer_albedo, v_uv).rgb;
    vec2 mr = texture(gbuffer_metallic_roughness, v_uv).rg;
    float metallic = clamp(mr.r, 0.0, 1.0);
    float roughness = clamp(mr.g, 0.0, 1.0);

    // Camera position from push constant
    vec3 V = normalize(camera_position - position);

    float shadowFactor = calculateShadow(position, normal);

    // Only direct lighting, no ambient/IBL/emissive
    vec3 direct = brdf(normal, V, albedo, roughness, metallic, position) * shadowFactor;
    outColor = vec4(direct, 1.0);
}
