#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool HAS_ALBEDO_TEXTURE = false;
layout(constant_id = 2) const bool HAS_METALLIC_ROUGHNESS_TEXTURE = false;
layout(constant_id = 3) const bool HAS_NORMAL_TEXTURE = false;
layout(constant_id = 4) const bool HAS_DISPLACEMENT_TEXTURE = false;
layout(constant_id = 5) const bool HAS_EMISSIVE_TEXTURE = false;

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;
const uint MAX_LIGHTS = 10;
const uint POINT_LIGHT = 0;
const uint DIRECTIONAL_LIGHT = 1;
const uint SPOT_LIGHT = 2;
const float PI = 3.14159265359;

struct Light {
    mat4 viewProj;
    vec4 color;
    vec4 position;
    vec4 direction;
    uint kind;
    float angle;
    float radius;
    uint hasShadow;
};
// camera set = 0
layout(set = 0, binding = 0) uniform SceneUniforms {
    mat4 view;
    mat4 proj;
};
// lights and shadow maps set = 1
layout(set = 1, binding = 0) uniform LightUniforms {
    Light lights[MAX_LIGHTS];
    uint lightCount;
};
layout(set = 1, binding = 1) uniform sampler2D shadowMaps[MAX_LIGHTS];
layout(set = 1, binding = 2) uniform samplerCube cubeShadowMaps[MAX_LIGHTS];
// textures and samplers set = 2
layout(set = 2, binding = 0) uniform texture2D textures[];
layout(set = 2, binding = 1) uniform sampler samplers[];

layout(push_constant) uniform PushConstants {
    mat4 world;
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint displacement_index;
    uint emissive_index;
    uint environment_index;
    uint brdf_lut_index;
    uint bone_matrix_offset;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    float padding;
};

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;
layout(location = 0) out vec4 outColor;

const vec3 ambientColor = vec3(0.0, 0.5, 1.0);
const float ambientStrength = 0.2;
const float specularStrength = 0.8;
const float shininess = 20.0;
const float diffuseStrength = 1.0;

// Convert a direction vector to equirectangular UV coordinates
vec2 dirToEquirectUV(vec3 dir) {
    float u = atan(dir.z, dir.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(-dir.y, -1.0, 1.0)) / PI;
    return vec2(u, v);
}

float linearizeDepth(float depth, float near, float far) {
    // Converts depth from [0,1] (texture) to linear view space depth
    float z = depth * 2.0 - 1.0; // [0,1] to [-1,1]
    return (2.0 * near * far) / (far + near - z * (far - near)); // [-1,1] to [near,far]
}

float textureProj(uint lightIdx, vec3 shadowCoord) {
    Light light = lights[lightIdx];
    vec3 surfaceToLight = light.position.xyz - position;
    float shadowDepth = texture(shadowMaps[lightIdx], shadowCoord.xy).r;
    float currentDepth = shadowCoord.z;
    float near = 0.01;
    float far = light.radius;

    // Only apply linearization for spotlights (perspective projection)
    if (light.kind == SPOT_LIGHT) {
        float bias = max(0.4 * (1.0 - dot(normalize(normal), normalize(-surfaceToLight))), 0.05);
        float shadowDepthLinear = linearizeDepth(shadowDepth, near, far);
        float currentDepthLinear = linearizeDepth(currentDepth, near, far);
        return (currentDepthLinear > shadowDepthLinear + bias) ? 0.1 : 1.0;
    } else {
        float bias = max(0.1 * (1.0 - dot(normalize(normal), normalize(-surfaceToLight))), 0.05);
        // Directional lights use orthographic projection (linear)
        return (currentDepth > shadowDepth + bias) ? 0.1 : 1.0;
    }
}

float filterPCF(uint lightIdx, vec3 projCoords) {
    float shadow = 0.0;
    vec2 texelSize = 1.0 / textureSize(shadowMaps[lightIdx], 0);
    for (int x = -1; x <= 1; x++) {
        for (int y = -1; y <= 1; y++) {
            vec3 uv = projCoords + vec3(x*texelSize.x, y*texelSize.y, 0.0);
            shadow += textureProj(lightIdx, uv);
        }
    }
    shadow /= 9.0;
    return shadow;
}

float calculateShadow(uint lightIdx) {
    if (lights[lightIdx].hasShadow == 0) return 1;
    if (lights[lightIdx].kind == POINT_LIGHT) {
        vec3 lightToSurface = position - lights[lightIdx].position.xyz;
        float shadowDepth = texture(cubeShadowMaps[lightIdx], normalize(lightToSurface)).r;
        // Reconstruct linear depth from perspective depth
        float near = 0.01;
        float far = lights[lightIdx].radius;
        shadowDepth = linearizeDepth(shadowDepth, near, far);
        float currentDepth = max(abs(lightToSurface.x), max(abs(lightToSurface.y), abs(lightToSurface.z)));
        // return fract(shadowDepth/currentDepth);
        float bias_max = pow(lights[lightIdx].radius, 0.3)*0.5;
        float bias_min = bias_max*0.1;
        float bias = max(bias_max * (1.0 - dot(normalize(normal), normalize(lightToSurface))), bias_min);
        return smoothstep(currentDepth - bias, currentDepth, shadowDepth);
    }
    vec4 lightSpacePos = lights[lightIdx].viewProj * vec4(position, 1.0);
    vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
    shadowCoord = shadowCoord * 0.5 + 0.5;
    bool outOfSight = shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
                shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
                shadowCoord.z < 0.0 || shadowCoord.z > 1.0;
    if (outOfSight) return 1.0;
    return filterPCF(lightIdx, shadowCoord);
}

vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic) {
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    vec3 Lo = vec3(0.0);
    for (int i = 0; i < min(lightCount, MAX_LIGHTS); i++) {
        Light light = lights[i];
        vec3 L = light.kind == DIRECTIONAL_LIGHT ? normalize(-light.direction.xyz) : normalize(light.position.xyz - position);
        vec3 H = normalize(V + L);
        float distance = light.kind == DIRECTIONAL_LIGHT ? 1.0 : length(light.position.xyz - position);
        float attenuation = 2.0;
        if (light.kind != DIRECTIONAL_LIGHT) {
            float norm_dist = distance / max(0.01, light.radius);
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
        float shadow = calculateShadow(i);
        Lo += (kD * albedo / PI + spec) * light.color.rgb * NdotL * attenuation * shadow;
    }
    return Lo;
}

void main() {
    vec3 cameraPosition = -inverse(view)[3].xyz;
    vec3 albedo = HAS_ALBEDO_TEXTURE ? texture(sampler2D(textures[albedo_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).rgb : color.rgb;
    float occlusion = HAS_METALLIC_ROUGHNESS_TEXTURE ? texture(sampler2D(textures[metallic_roughness_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).r : 1.0;
    float roughness = HAS_METALLIC_ROUGHNESS_TEXTURE ? texture(sampler2D(textures[metallic_roughness_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).g : roughness_value;
    float metallic = HAS_METALLIC_ROUGHNESS_TEXTURE ? texture(sampler2D(textures[metallic_roughness_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).b : metallic_value;
    vec3 emissive = HAS_EMISSIVE_TEXTURE ? texture(sampler2D(textures[emissive_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).rgb : (color.rgb * emissive_value);
    metallic = clamp(metallic, 0.0, 1.0);
    roughness = clamp(roughness, 0.0, 1.0);
    vec3 N = normalize(normal);
    if (HAS_NORMAL_TEXTURE && false) {
        vec3 tangentNormal = texture(sampler2D(textures[normal_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).xyz * 2.0 - 1.0;
        N = normalize(tangentNormal);
    }
    vec3 displacedPosition = position;
    if (HAS_DISPLACEMENT_TEXTURE) {
        float disp = texture(sampler2D(textures[displacement_index], samplers[SAMPLER_LINEAR_REPEAT]), uv).r;
        displacedPosition += N * disp;
    }
    vec3 V = normalize(cameraPosition - displacedPosition);
    vec3 R = reflect(-V, N);
    vec3 F0 = mix(vec3(0.04), albedo, metallic);
    // Diffuse: sample environment in the normal direction (approximate)
    vec2 uvN = dirToEquirectUV(N);
    vec3 diffuseIBL = texture(sampler2D(textures[environment_index], samplers[SAMPLER_LINEAR_REPEAT]), uvN).rgb * albedo;
    // Specular: sample environment in the reflection direction (no LOD, no roughness blur)
    vec2 uvR = dirToEquirectUV(R);
    vec3 prefilteredColor = texture(sampler2D(textures[environment_index], samplers[SAMPLER_LINEAR_REPEAT]), uvR).rgb;
    float NdotV = max(dot(N, V), 0.0);
    vec2 brdfSample = texture(sampler2D(textures[brdf_lut_index], samplers[SAMPLER_LINEAR_REPEAT]), vec2(NdotV, roughness)).rg;
    // Attenuate specular by (1.0 - roughness) to fake roughness blur
    vec3 specularIBL = prefilteredColor * (F0 * brdfSample.x + brdfSample.y) * (1.0 - roughness)*0.1;
    vec3 kS = F0 + (1.0 - F0) * pow(1.0 - NdotV, 5.0);
    vec3 kD = (vec3(1.0) - kS) * (1.0 - metallic);
    vec3 ambient = kD * diffuseIBL + specularIBL + emissive;
    vec3 colorOut = ambient * 0.5 + brdf(N, V, albedo, roughness, metallic);
    outColor = vec4(colorOut, 1.0);
}
