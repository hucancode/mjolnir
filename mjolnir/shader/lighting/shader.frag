#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint MAX_SHADOW_MAPS = 10;
const float PI = 3.14159265359;

layout(location = 0) in vec2 v_uv;
layout(location = 0) out vec4 outColor;

const int POINT_LIGHT = 0;
const int DIRECTIONAL_LIGHT = 1;
const int SPOT_LIGHT = 2;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(set = 2, binding = 0) uniform sampler2D gbuffer_position;
layout(set = 2, binding = 1) uniform sampler2D gbuffer_normal;
layout(set = 2, binding = 2) uniform sampler2D gbuffer_albedo;
layout(set = 2, binding = 3) uniform sampler2D gbuffer_metallic_roughness;
layout(set = 2, binding = 4) uniform sampler2D gbuffer_emissive;
layout(set = 2, binding = 5) uniform sampler2D shadow_maps[MAX_SHADOW_MAPS];
layout(set = 2, binding = 6) uniform samplerCube cube_shadow_maps[MAX_SHADOW_MAPS];

// We have a budget of 128 bytes for push constants
// We can fit 2 matrices in here
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

// Convert a direction vector to equirectangular UV coordinates
vec2 dirToEquirectUV(vec3 dir) {
    float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(-dir.y, -1.0, 1.0)) / PI;
    return vec2(u, v);
}

float linearizeDepth(float depth, float near, float far) {
    // Converts depth from [0,1] (texture) to [near, far]
    float z = depth * 2.0 - 1.0;
    return (2.0 * near * far) / (far + near - z * (far - near));
}

float calculateShadow(vec3 fragPos, vec3 N) {
    if (light_kind == DIRECTIONAL_LIGHT) {
        vec4 lightSpacePos = light_view_proj * vec4(fragPos, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        shadowCoord = shadowCoord * 0.5 + 0.5;
        if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
            shadowCoord.z < 0.0 || shadowCoord.z > 1.0) {
            return 1.0;
        }
        float shadowDepth = texture(shadow_maps[shadow_map_id], shadowCoord.xy).r;
        float bias = max(0.1 * (1.0 - dot(N, normalize(-light_direction.xyz))), 0.05);
        return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
    } else if (light_kind == POINT_LIGHT) {
        vec3 lightToFrag = fragPos - light_position.xyz;
        float currentDepth = length(lightToFrag);
        float shadowMapDepth = texture(cube_shadow_maps[shadow_map_id], lightToFrag).r;
        shadowMapDepth = linearizeDepth(shadowMapDepth, 0.01, light_radius);
        float bias = max(0.5 * (1.0 - dot(N, normalize(lightToFrag))), 0.01);
        return 1.0 - smoothstep(bias, bias*2, currentDepth - shadowMapDepth);
    } else if (light_kind == SPOT_LIGHT) {
        vec4 lightSpacePos = light_view_proj * vec4(fragPos, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        shadowCoord = shadowCoord * 0.5 + 0.5;
        if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
            shadowCoord.z < 0.0 || shadowCoord.z > 1.0) {
            return 1.0;
        }
        float shadowDepth = texture(shadow_maps[shadow_map_id], shadowCoord.xy).r;
        float bias = max(0.1 * (1.0 - dot(N, normalize(light_position.xyz - fragPos))), 0.05);
        return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
    }
    return 1.0;
}

vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic, vec3 fragPos) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 Lo = vec3(0.0);
    // Only one light for now (deferred pass is usually per-light or with a light buffer)
    vec3 L = light_kind == DIRECTIONAL_LIGHT ? normalize(-light_direction.xyz) : normalize(light_position.xyz - fragPos);
    vec3 H = normalize(V + L);
    float distance = light_kind == DIRECTIONAL_LIGHT ? 1.0 : length(light_position.xyz - fragPos);
    float attenuation = light_radius;
    if (light_kind != DIRECTIONAL_LIGHT) {
        float norm_dist = distance / max(0.01, light_radius);
        attenuation *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
    }

    // Spot light cone attenuation
    if (light_kind == SPOT_LIGHT) {
        vec3 lightToFrag = normalize(fragPos - light_position.xyz);
        float cosTheta = dot(lightToFrag, normalize(light_direction.xyz));
        float cosOuterCone = cos(light_angle);
        float cosInnerCone = cos(light_angle * 0.7); // Inner cone is 70% of outer cone

        // Smooth falloff from inner to outer cone
        float spotEffect = smoothstep(cosOuterCone, cosInnerCone, cosTheta);
        attenuation *= spotEffect;
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
    vec3 V = normalize(camera_position - position);
    float shadowFactor = calculateShadow(position, normal);
    // Only direct lighting, no ambient/IBL/emissive
    vec3 direct = brdf(normal, V, albedo, roughness, metallic, position) * shadowFactor;
    outColor = vec4(direct, 1.0);
}
