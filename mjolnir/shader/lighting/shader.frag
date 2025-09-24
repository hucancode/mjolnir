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

struct Camera {
    mat4 view;
    mat4 projection;
    vec4 viewport_params;
    vec4 position;
    vec4 frustum_planes[6];
};

// Bindless camera buffer (set 0, binding 0)
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
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
    uint position_texture_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    uint depth_texture_index;
    uint input_image_index;
};

// Convert a direction vector to equirectangular UV coordinates
vec2 dirToEquirectUv(vec3 dir) {
    float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(-dir.y, -1.0, 1.0)) / PI;
    return vec2(u, v);
}

float linearizeDepth(float depth, float near, float far) {
    // Converts depth from [0,1] to [near, far]
    float z = depth * 2.0 - 1.0;
    return (2.0 * near * far) / (far + near - z * (far - near));
}

float calculateShadow(vec3 fragPos, vec3 n, Camera lightCamera) {
    if (light_kind == DIRECTIONAL_LIGHT) {
        // WIP, currently we don't calculate directional light's shadow
        return 1.0;
    } else if (light_kind == POINT_LIGHT) {
        vec3 lightToFrag = fragPos - light_position;
        vec3 coord = normalize(lightToFrag);
        float currentDepth = length(lightToFrag);
        float shadowDepth = texture(samplerCube(cube_textures[shadow_map_id], samplers[SAMPLER_LINEAR_CLAMP]), coord).r;
        float near = 0.1;
        float far = light_radius;
        float normalizedCurrentDepth = (currentDepth - near) / (far - near);
        float bias = 0.001; // Small bias to prevent acne
        return (normalizedCurrentDepth > shadowDepth + bias) ? 0.1 : 1.0;
    } else if (light_kind == SPOT_LIGHT) {
        vec3 lightToFrag = fragPos - light_position;
        float currentDepth = length(lightToFrag);
        vec4 lightSpacePos = lightCamera.projection * lightCamera.view * vec4(fragPos, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        shadowCoord = shadowCoord * 0.5 + 0.5;
        if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
            shadowCoord.z < 0.0 || shadowCoord.z > 1.0) {
            return 1.0;
        }
        float near = 0.1;
        float far = light_radius;
        float normalizedCurrentDepth = (currentDepth - near) / (far - near);
        float shadowDepth = texture(sampler2D(textures[shadow_map_id], samplers[SAMPLER_LINEAR_CLAMP]), shadowCoord.xy).r;
        float bias = 0.001;
        return (normalizedCurrentDepth > shadowDepth + bias) ? 0.0 : 1.0;
    }
    return 1.0;
}

vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic, vec3 fragPos) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 Lo = vec3(0.0);
    // Light direction and distance
    vec3 L = light_kind == DIRECTIONAL_LIGHT ? normalize(-light_direction) : normalize(light_position - fragPos);
    vec3 H = normalize(V + L);
    float distance = light_kind == DIRECTIONAL_LIGHT ? 1.0 : length(light_position - fragPos);
    float attenuation = light_radius;
    if (light_kind != DIRECTIONAL_LIGHT) {
        float norm_dist = distance / max(0.01, light_radius);
        attenuation *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
    }
    if (light_kind == SPOT_LIGHT) {
        vec3 lightToFrag = normalize(fragPos - light_position);
        float cosTheta = dot(-lightToFrag, normalize(light_direction));
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
    Lo += (kD * albedo / PI + spec) * light_color * NdotL * attenuation;
    return Lo;
}

vec3 colorBand(float x) {
    vec3 ret;
    if (x < 0.25) {
        ret = vec3(1.0, 0.0, 0.0); // Red
    } else if (x < 0.5) {
        ret = vec3(0.0, 0.0, 1.0); // Blue
    } else if (x < 0.75) {
        ret = vec3(0.0, 1.0, 0.0); // Green
    } else {
        ret = vec3(1.0, 1.0, 1.0); // White
    }
    return ret;
}

void main() {
    // Get cameras from bindless buffer
    Camera camera = camera_buffer.cameras[scene_camera_idx];
    vec2 uv = (gl_FragCoord.xy / camera.viewport_params.xy);
    vec3 position = texture(sampler2D(textures[position_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz;
    float depth = texture(sampler2D(textures[depth_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).r;
    vec3 normal = texture(sampler2D(textures[normal_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).xyz * 2.0 - 1.0;
    vec3 albedo = texture(sampler2D(textures[albedo_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[metallic_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).rg;
    float metallic = clamp(mr.r, 0.0, 1.0);
    float roughness = clamp(mr.g, 0.0, 1.0);
    roughness = max(roughness, 0.05);
    vec3 V = normalize(camera.position.xyz - position);
    Camera lightCamera = camera_buffer.cameras[light_camera_idx];
    float shadowFactor = calculateShadow(position, normal, lightCamera);
    vec3 direct = brdf(normal, V, albedo, roughness, metallic, position);
    outColor = vec4(direct * shadowFactor, 1.0);
    // outColor = vec4(vec3(shadowFactor), 1.0);
    // === DEBUG COLOR BANDS ===
    // if (false) {
    //     vec2 screenUV = gl_FragCoord.xy / camera_buffer.cameras[push.scene_camera_idx].viewport_size;
    //     vec4 lightSpacePos = light_camera.projection * light_camera.view * vec4(position, 1.0);
    //     vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
    //     shadowCoord = shadowCoord * 0.5 + 0.5;
    //     float currentDepth = length(position - push.light_position) / push.light_radius;
    //     float shadowDepth = texture(sampler2D(textures[push.shadow_map_id], samplers[SAMPLER_LINEAR_CLAMP]), shadowCoord.xy).r;
    //     outColor = vec4(colorBand(currentDepth), 1.0);
    // }
}
