#version 450
#extension GL_EXT_nonuniform_qualifier : require

const float PI = 3.14159265359;

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 1) const uint MAX_CUBE_TEXTURES = 1u;
layout(constant_id = 2) const uint MAX_SAMPLERS = 1u;
layout(constant_id = 3) const uint SAMPLER_NEAREST_CLAMP = 0u;
layout(constant_id = 4) const uint SAMPLER_LINEAR_CLAMP = 1u;
layout(constant_id = 5) const uint SAMPLER_NEAREST_REPEAT = 2u;
layout(constant_id = 6) const uint SAMPLER_LINEAR_REPEAT = 3u;
layout(constant_id = 7) const uint POINT_LIGHT = 0u;
layout(constant_id = 8) const uint DIRECTIONAL_LIGHT = 1u;
layout(constant_id = 9) const uint SPOT_LIGHT = 2u;

layout(location = 0) out vec4 outColor;

struct Camera {
    mat4 view;
    mat4 projection;
    vec4 viewport_params;
    vec4 position;
    vec4 frustum_planes[6];
};

struct SphericalCamera {
    mat4 projection;
    vec4 position; // center.xyz, radius in w
    vec2 near_far;
    vec2 _padding;
};

struct LightData {
    vec4 color;
    float radius;
    float angle_inner;
    float angle_outer;
    uint type;
    uint node_index;
    uint camera_index;
    uint cast_shadow;
    uint _padding;
};

struct DynamicLightData {
    vec4 position;
    uint shadow_map;
    uint _padding[3];
};

// Bindless camera buffer (set 0, binding 0) - Regular cameras
layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;
layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];
// Lights buffer (set 2, binding 0)
layout(set = 2, binding = 0) readonly buffer LightsBuffer {
    LightData lights[];
} lights_buffer;
// World matrices buffer (set 3, binding 0)
layout(set = 3, binding = 0) readonly buffer WorldMatricesBuffer {
    mat4 world_matrices[];
} world_matrices_buffer;
// Spherical camera buffer (set 4, binding 0) - For point light shadows
layout(set = 4, binding = 0) readonly buffer SphericalCameraBuffer {
    SphericalCamera spherical_cameras[];
} spherical_camera_buffer;
// Per-frame dynamic light data buffer (set 5, binding 0) - Position + shadow map synchronized
layout(set = 5, binding = 0) readonly buffer DynamicLightDataBuffer {
    DynamicLightData dynamic_light_data[];
} dynamic_light_data_buffer;

layout(push_constant) uniform PushConstant {
    uint light_index;
    uint scene_camera_idx;
    uint position_texture_index;
    uint normal_texture_index;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint emissive_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint padding[3];
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

bool has_shadow_resource(uint light_idx) {
    uint shadow_map = dynamic_light_data_buffer.dynamic_light_data[light_idx].shadow_map;
    LightData light = lights_buffer.lights[light_idx];
    if (light.type == POINT_LIGHT) {
        return shadow_map < MAX_CUBE_TEXTURES;
    }
    return shadow_map < MAX_TEXTURES;
}

float calculateShadow(vec3 fragPos, vec3 n, LightData light, uint light_idx, vec3 light_position, vec3 light_direction) {
    if (light.cast_shadow == 0u) {
        return 1.0;
    }
    uint shadow_map = dynamic_light_data_buffer.dynamic_light_data[light_idx].shadow_map;
    if (shadow_map >= MAX_CUBE_TEXTURES && light.type == POINT_LIGHT) {
        return 1.0; // No valid shadow map for point light
    }
    if (shadow_map >= MAX_TEXTURES && (light.type == DIRECTIONAL_LIGHT || light.type == SPOT_LIGHT)) {
        return 1.0; // No valid shadow map for directional/spot light
    }
    if (light.type == DIRECTIONAL_LIGHT) {
        Camera lightCamera = camera_buffer.cameras[light.camera_index];
        vec4 lightSpacePos = lightCamera.projection * lightCamera.view * vec4(fragPos, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        // Transform XY from [-1,1] to [0,1], but Z is already [0,1] in Vulkan!
        shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
        shadowCoord.y = 1.0 - shadowCoord.y;
        // Only reject if XY is out of shadow map bounds
        if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0) {
            return 1.0;
        }
        shadowCoord.z = clamp(shadowCoord.z, 0.0, 1.0);
        vec3 lightDir = normalize(light_direction);
        float cosTheta = clamp(dot(n, lightDir), 0.0, 1.0);
        float bias = 0.005 * tan(acos(cosTheta));
        bias = clamp(bias, 0.001, 0.01);
        float shadowDepth = texture(sampler2D(textures[shadow_map], samplers[SAMPLER_LINEAR_CLAMP]), shadowCoord.xy).r;
        return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
    } else if (light.type == POINT_LIGHT) {
        vec3 lightToFrag = fragPos - light_position;
        // we must invert the direction for coordinate because the cube map has all faces oriented inward
        vec3 coord = normalize(-lightToFrag);
        float linearDepth = length(lightToFrag);
        float shadowDepth = texture(samplerCube(cube_textures[shadow_map], samplers[SAMPLER_LINEAR_CLAMP]), coord).r;
        SphericalCamera spherical_cam = spherical_camera_buffer.spherical_cameras[light.camera_index];
        float near = spherical_cam.near_far.x;
        float far = spherical_cam.near_far.y;
        // Linear depth mapping: [near, far] -> [0, 1]
        float currentDepth = (linearDepth - near) / (far - near);
        currentDepth = clamp(currentDepth, 0.0, 1.0);
        float cosTheta = clamp(dot(n, -lightToFrag), 0.0, 1.0);
        float bias = 0.0005 * tan(acos(cosTheta));
        bias = clamp(bias, 0.001, 0.01);
        float brightness = (currentDepth > shadowDepth + bias) ? 0.1 : 1.0;
        return brightness;
    } else if (light.type == SPOT_LIGHT) {
        Camera lightCamera = camera_buffer.cameras[light.camera_index];
        vec4 lightSpacePos = lightCamera.projection * lightCamera.view * vec4(fragPos, 1.0);
        vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
        // Transform XY from [-1,1] to [0,1], Z is already [0,1]
        shadowCoord.xy = shadowCoord.xy * 0.5 + 0.5;
        shadowCoord.y = 1.0 - shadowCoord.y;
        if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0) {
            return 1.0;
        }
        shadowCoord.z = clamp(shadowCoord.z, 0.0, 1.0);
        float shadowDepth = texture(sampler2D(textures[shadow_map], samplers[SAMPLER_LINEAR_CLAMP]), shadowCoord.xy).r;
        vec3 lightDir = normalize(light_position - fragPos);
        float cosTheta = clamp(dot(n, lightDir), 0.0, 1.0);
        float bias = 0.0005 * tan(acos(cosTheta));
        bias = clamp(bias, 0.001, 0.01);
        return (shadowCoord.z > shadowDepth + bias) ? 0.1 : 1.0;
    }
    return 1.0;
}

vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic, vec3 fragPos, LightData light, vec3 light_position, vec3 light_direction) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 Lo = vec3(0.0);
    vec3 light_color = light.color.rgb * light.color.a; // RGB * intensity
    // Light direction and distance (light_direction is already -Z forward direction)
    vec3 L = light.type == DIRECTIONAL_LIGHT ? normalize(light_direction) : normalize(light_position - fragPos);
    vec3 H = normalize(V + L);
    float distance = light.type == DIRECTIONAL_LIGHT ? 1.0 : length(light_position - fragPos);
    float attenuation = light.radius;
    if (light.type == POINT_LIGHT) {
        float norm_dist = distance / max(0.01, light.radius);
        attenuation *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
    }
    if (light.type == SPOT_LIGHT) {
        // Vector from cone tip to fragment
        vec3 tipToFrag = fragPos - light_position;
        vec3 cone_axis = normalize(light_direction);
        // Project onto cone axis to get distance along the axis
        float distance_along_axis = dot(tipToFrag, cone_axis);
        // Calculate perpendicular component (rejection from axis)
        vec3 projection_on_axis = distance_along_axis * cone_axis;
        vec3 perpendicular_component = tipToFrag - projection_on_axis;
        float radial_distance = length(perpendicular_component);
        // Cone radius at this distance: r = d * tan(angle)
        float cone_radius_at_height = distance_along_axis * tan(light.angle_outer);
        // Normalized radial distance: 0 = on centerline, 1 = at edge
        float normalized_radial = radial_distance / max(cone_radius_at_height, 0.001);
        // Smooth falloff from inner to outer angle
        float inner_outer_ratio = tan(light.angle_inner) / tan(light.angle_outer);
        float spotEffect = smoothstep(1.0, inner_outer_ratio, normalized_radial);
        float norm_dist = distance_along_axis / max(0.01, light.radius);
        spotEffect *= 1.0 - clamp(norm_dist * norm_dist, 0.0, 1.0);
        attenuation *= spotEffect;
    }
    float NdotL = max(dot(N, L), 0.0);
    float NdotV = max(dot(N, V), 0.01);
    float NdotH = max(dot(N, H), 0.0);
    // Cook-Torrance BRDF (GGX/Trowbridge-Reitz NDF)
    float alpha = roughness * roughness;
    float alpha2 = alpha * alpha;
    float denom = NdotH * NdotH * (alpha2 - 1.0) + 1.0;
    denom = max(denom, 0.001);
    float NDF = alpha2 / (PI * denom * denom);
    float k = pow(roughness + 1.0, 2.0) / 8.0;
    float G = NdotL / (NdotL * (1.0 - k) + k);
    G *= NdotV / (NdotV * (1.0 - k) + k);
    vec3 F = F0 + (1.0 - F0) * pow(1.0 - max(dot(H, V), 0.0), 5.0);
    vec3 spec = (NDF * G * F) / (4.0 * NdotV * NdotL + 0.01);
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
    if (light_index >= lights_buffer.lights.length()) {
        outColor = vec4(1.0, 0.0, 0.0, 1.0); // Red for invalid light index
        return;
    }
    if (scene_camera_idx >= camera_buffer.cameras.length()) {
        outColor = vec4(0.0, 1.0, 0.0, 1.0); // Green for invalid scene camera index
        return;
    }
    // Get light data from the lights buffer
    LightData light = lights_buffer.lights[light_index];
    // Additional bounds check for node index
    if (light.node_index >= world_matrices_buffer.world_matrices.length()) {
        outColor = vec4(1.0, 1.0, 0.0, 1.0); // Yellow for invalid node index
        return;
    }
    // Only validate camera index if shadows are enabled
    bool will_use_shadow = (light.cast_shadow != 0u) && has_shadow_resource(light_index);
    if (will_use_shadow && light.camera_index >= camera_buffer.cameras.length()) {
        outColor = vec4(1.0, 0.0, 1.0, 1.0); // Magenta for invalid light camera index
        return;
    }
    Camera camera = camera_buffer.cameras[scene_camera_idx];
    vec2 uv = (gl_FragCoord.xy / camera.viewport_params.xy);
    vec3 position = texture(sampler2D(textures[position_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).xyz;
    float depth = texture(sampler2D(textures[depth_texture_index], samplers[SAMPLER_NEAREST_CLAMP]), uv).r;
    vec3 normal = normalize(texture(sampler2D(textures[normal_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).xyz * 2.0 - 1.0);
    vec3 albedo = texture(sampler2D(textures[albedo_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).rgb;
    vec2 mr = texture(sampler2D(textures[metallic_texture_index], samplers[SAMPLER_LINEAR_CLAMP]), uv).rg;
    float metallic = clamp(mr.r, 0.0, 1.0);
    float roughness = clamp(mr.g, 0.0, 1.0);
    roughness = max(roughness, 0.08);
    vec3 V = normalize(camera.position.xyz - position);
    vec3 light_position = dynamic_light_data_buffer.dynamic_light_data[light_index].position.xyz;
    mat4 lightWorldMatrix = world_matrices_buffer.world_matrices[light.node_index];
    vec3 light_direction = lightWorldMatrix[2].xyz;
    float shadowFactor = calculateShadow(position, normal, light, light_index, light_position, light_direction);
    vec3 direct = brdf(normal, V, albedo, roughness, metallic, position, light, light_position, light_direction);
    direct = direct / (direct + vec3(1.0));
    outColor = vec4(direct * shadowFactor, 1.0);
    // outColor.b = clamp(outColor.b, 0.1, 1.0);
}
