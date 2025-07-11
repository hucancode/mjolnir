#version 450
#extension GL_EXT_nonuniform_qualifier : require

const float PI = 3.14159265359;

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;

layout(location = 0) out vec4 outColor;

const int POINT_LIGHT = 0;
const int DIRECTIONAL_LIGHT = 1;
const int SPOT_LIGHT = 2;

struct CameraUniform {
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
    CameraUniform cameras[];
} camera_buffer;
layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

layout(push_constant) uniform LightPushConstant {
    uint scene_camera_idx;
    uint light_camera_idx;
    uint shadow_map_id;
    uint light_kind;
    vec3 light_color;
    float light_angle;
    vec3 light_position;
    float light_radius;
    vec3 light_direction;
    uint light_cast_shadow;
    uint gbuffer_position_index;
    uint gbuffer_normal_index;
    uint gbuffer_albedo_index;
    uint gbuffer_metallic_index;
    uint gbuffer_emissive_index;
    uint gbuffer_depth_index;
    uint input_image_index;
} push;

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

float calculateShadow(vec3 fragPos, vec3 N, CameraUniform light_camera) {
    if (push.light_kind == DIRECTIONAL_LIGHT) {
        vec4 lightSpacePos = light_camera.projection * light_camera.view * vec4(fragPos, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        shadowCoord = shadowCoord * 0.5 + 0.5;
        if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
            shadowCoord.z < 0.0 || shadowCoord.z > 1.0) {
            return 1.0;
        }
        float shadowDepth = texture(sampler2D(textures[push.shadow_map_id], samplers[SAMPLER_LINEAR_CLAMP]), shadowCoord.xy).r;
        float bias = max(0.1 * (1.0 - dot(N, normalize(-push.light_direction))), 0.05);
        return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
    } else if (push.light_kind == POINT_LIGHT) {
        vec3 lightToFrag = fragPos - push.light_position;
        vec3 coord = normalize(lightToFrag);
        float currentDepth = length(lightToFrag);
        float shadowDepth = texture(samplerCube(cube_textures[push.shadow_map_id], samplers[SAMPLER_LINEAR_CLAMP]), coord).r;
        return shadowDepth;
        shadowDepth = linearizeDepth(shadowDepth, 0.1, push.light_radius);
        float bias = max(0.05 * (1.0 - dot(N, normalize(lightToFrag))), 0.01);
        return (currentDepth > shadowDepth + bias) ? 0.0 : 1.0;
    } else if (push.light_kind == SPOT_LIGHT) {
        vec4 lightSpacePos = light_camera.projection * light_camera.view * vec4(fragPos, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        shadowCoord = shadowCoord * 0.5 + 0.5;
        // Simple bounds check
        if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
            shadowCoord.z < 0.0 || shadowCoord.z > 1.0) {
            return 1.0; // No shadow outside frustum
        }
        float shadowDepth = texture(sampler2D(textures[push.shadow_map_id], samplers[SAMPLER_LINEAR_CLAMP]), shadowCoord.xy).r;
        float bias = max(0.05 * (1.0 - dot(N, normalize(lightToFrag))), 0.01);
        return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
    }
    return 1.0;
}

vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic, vec3 fragPos) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 Lo = vec3(0.0);
    // Light direction and distance
    vec3 L = push.light_kind == DIRECTIONAL_LIGHT ? normalize(-push.light_direction) : normalize(push.light_position - fragPos);
    vec3 H = normalize(V + L);
    float distance = push.light_kind == DIRECTIONAL_LIGHT ? 1.0 : length(push.light_position - fragPos);
    float attenuation = push.light_radius;
    if (push.light_kind != DIRECTIONAL_LIGHT) {
        float norm_dist = distance / max(0.01, push.light_radius);
        attenuation *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
    }
    if (push.light_kind == SPOT_LIGHT) {
        vec3 lightToFrag = normalize(fragPos - push.light_position);
        float cosTheta = dot(-lightToFrag, normalize(push.light_direction)); // Note: negative lightToFrag
        float spotEffect = smoothstep(0.9, 1.1, abs(cosTheta));
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
    Lo += (kD * albedo / PI + spec) * push.light_color * NdotL * attenuation;
    return Lo;
}

void main() {
    // Get cameras from bindless buffer
    CameraUniform camera = camera_buffer.cameras[push.scene_camera_idx];
    vec2 uv = (gl_FragCoord.xy / camera.viewport_size);
    vec3 position = texture(sampler2D(textures[push.gbuffer_position_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz;
    float depth = texture(sampler2D(textures[push.gbuffer_depth_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).r;
    vec3 normal = texture(sampler2D(textures[push.gbuffer_normal_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz * 2.0 - 1.0;
    vec3 albedo = texture(sampler2D(textures[push.gbuffer_albedo_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[push.gbuffer_metallic_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rg;
    float metallic = clamp(mr.r, 0.0, 1.0);
    float roughness = clamp(mr.g, 0.0, 1.0);
    roughness = max(roughness, 0.05);
    vec3 V = normalize(camera.camera_position - position);
    CameraUniform light_camera = camera_buffer.cameras[push.light_camera_idx];
    float shadowFactor = calculateShadow(position, normal, light_camera);
    vec3 direct = brdf(normal, V, albedo, roughness, metallic, position);

    // DEBUG: Visualize spot light shadow map data
    if (push.light_kind == SPOT_LIGHT && false) {
        vec4 lightSpacePos = light_camera.projection * light_camera.view * vec4(position, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        shadowCoord = shadowCoord * 0.5 + 0.5;

        // Show shadow coordinates as color for debugging
        if (shadowCoord.x >= 0.0 && shadowCoord.x <= 1.0 &&
            shadowCoord.y >= 0.0 && shadowCoord.y <= 1.0 &&
            shadowCoord.z >= 0.0 && shadowCoord.z <= 1.0) {
            float shadowDepth = texture(sampler2D(textures[push.shadow_map_id], samplers[SAMPLER_NEAREST_CLAMP]), shadowCoord.xy).r;
            outColor = vec4(vec3(shadowDepth), 1.0);
            // Visualize: Red=shadow map depth, Green=current depth, Blue=shadow factor
            return;
        }
            outColor = vec4(1,0,0, 1.0);
            return;
    }

    outColor = vec4(vec3(pow(shadowFactor, 10)), 1.0);
}
