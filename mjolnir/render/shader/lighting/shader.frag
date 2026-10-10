#version 450
#extension GL_EXT_nonuniform_qualifier : require

const float PI = 3.14159265359;

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 3) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 4) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 5) const uint SAMPLER_LINEAR_REPEAT = 3u;
layout(constant_id = 6) const uint LIGHT_TYPE = 0u;

const uint LIGHT_POINT = 0u;
const uint LIGHT_SPOT = 1u;
const uint LIGHT_DIRECTIONAL = 2u;
const uint NO_SHADOW = 0xFFFFu;

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

// Indices are packed two per uint, low 16 bits first.
layout(push_constant) uniform PushConstant {
    mat4  shadow_view_projection;
    vec4  light_color;
    vec3  position;
    float angle_inner;
    vec3  direction;
    float radius;
    float angle_outer;
    uint  shadow_and_camera_indices;
    uint  position_and_normal_indices;
    uint  albedo_and_metallic_indices;
};

// Direction from the fragment towards the light.
vec3 lightDirection(vec3 fragPos) {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) return normalize(-direction);
    return normalize(position - fragPos);
}

// Cube map storing linear depth from the light.
float pointShadow(vec3 fragPos, vec3 n, uint shadow_idx) {
    if (shadow_idx >= MAX_CUBE_TEXTURES) return 1.0;
    vec3 lightToFrag = fragPos - position;
    vec3 coord = normalize(lightToFrag);
    float linearDepth = length(lightToFrag);
    float shadowDepth = texture(samplerCube(cube_textures[shadow_idx], samplers[SAMPLER_LINEAR_CLAMP]), coord).r;
    float currentDepth = clamp((linearDepth - 0.1) / (radius - 0.1), 0.0, 1.0);
    float cosTheta = clamp(dot(n, -lightToFrag), 0.0, 1.0);
    float bias = clamp(0.0005 * tan(acos(cosTheta)), 0.001, 0.01);
    return (currentDepth > shadowDepth + bias) ? 0.1 : 1.0;
}

// 2D map projected with shadow_view_projection.
float projectedShadow(vec3 fragPos, vec3 n, uint shadow_idx) {
    if (shadow_idx >= MAX_TEXTURES) return 1.0;
    vec4 lightSpacePos = shadow_view_projection * vec4(fragPos, 1.0);
    vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
    shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
    shadowCoord.y = 1.0 - shadowCoord.y;
    if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
        shadowCoord.y < 0.0 || shadowCoord.y > 1.0) {
        return 1.0;
    }
    shadowCoord.z = clamp(shadowCoord.z, 0.0, 1.0);
    float shadowDepth = texture(sampler2D(textures[shadow_idx], samplers[SAMPLER_LINEAR_CLAMP]), shadowCoord.xy).r;
    float cosTheta = clamp(dot(n, lightDirection(fragPos)), 0.0, 1.0);
    float slope = LIGHT_TYPE == LIGHT_DIRECTIONAL ? 0.005 : 0.0005;
    float bias = clamp(slope * tan(acos(cosTheta)), 0.001, 0.01);
    return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
}

float calculateShadow(vec3 fragPos, vec3 n, uint shadow_idx) {
    if (shadow_idx == NO_SHADOW) return 1.0;
    if (LIGHT_TYPE == LIGHT_POINT) return pointShadow(fragPos, n, shadow_idx);
    return projectedShadow(fragPos, n, shadow_idx);
}

float attenuation(vec3 fragPos) {
    if (LIGHT_TYPE == LIGHT_DIRECTIONAL) return 1.0;
    if (LIGHT_TYPE == LIGHT_POINT) {
        float norm_dist = length(position - fragPos) / max(0.01, radius);
        return radius * (1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0));
    }
    vec3 tipToFrag = fragPos - position;
    vec3 cone_axis = normalize(direction);
    float distance_along_axis = dot(tipToFrag, cone_axis);
    float radial_distance = length(tipToFrag - distance_along_axis * cone_axis);
    float cone_radius_at_height = distance_along_axis * tan(angle_outer);
    float normalized_radial = radial_distance / max(cone_radius_at_height, 0.001);
    float inner_outer_ratio = tan(angle_inner) / tan(angle_outer);
    float spotEffect = smoothstep(1.0, inner_outer_ratio, normalized_radial);
    float norm_dist = distance_along_axis / max(0.01, radius);
    spotEffect *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
    return radius * spotEffect;
}

// Cook-Torrance BRDF
vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic, vec3 fragPos) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 light_col = light_color.rgb * light_color.a;
    vec3 L = lightDirection(fragPos);
    vec3 H = normalize(V + L);
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.01);
    float NdotH = max(dot(N, H), 0.0);
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float denom = max(NdotH * NdotH * (alpha2 - 1.0) + 1.0, 0.001);
    float NDF = alpha2 / (PI * denom * denom);
    float k = pow(roughness + 1.0, 2.0) / 8.0;
    float G = NdotL / (NdotL * (1.0 - k) + k);
    G *= NdotV / (NdotV * (1.0 - k) + k);
    vec3 F = F0 + (1.0 - F0) * pow(1.0 - max(dot(H, V), 0.0), 5.0);
    vec3 spec = NDF * G * F / (4.0 * NdotV * NdotL + 0.01);
    vec3 kS = clamp(F, 0.0, 1.0);
    vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);
    return (kD * albedo / PI + spec) * light_col * NdotL * attenuation(fragPos);
}

void main() {
    uint shadow_map_idx = shadow_and_camera_indices & 0xFFFFu;
    uint scene_camera_idx = shadow_and_camera_indices >> 16u;
    uint position_texture_index = position_and_normal_indices & 0xFFFFu;
    uint normal_texture_index = position_and_normal_indices >> 16u;
    uint albedo_texture_index = albedo_and_metallic_indices & 0xFFFFu;
    uint metallic_texture_index = albedo_and_metallic_indices >> 16u;

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
    float shadowFactor = calculateShadow(fragPos, normal, shadow_map_idx);
    vec3 direct = brdf(normal, V, albedo, roughness, metallic, fragPos);

    outColor = vec4(direct * shadowFactor, 1.0);
}
