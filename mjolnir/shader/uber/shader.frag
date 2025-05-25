#version 450

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool HAS_ALBEDO_TEXTURE = false;
layout(constant_id = 2) const bool HAS_METALLIC_ROUGHNESS_TEXTURE = false;
layout(constant_id = 3) const bool HAS_NORMAL_TEXTURE = false;
layout(constant_id = 4) const bool HAS_DISPLACEMENT_TEXTURE = false;
layout(constant_id = 5) const bool HAS_EMISSIVE_TEXTURE = false;

const uint MAX_LIGHTS = 5;
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

layout(set = 0, binding = 0) uniform SceneUniforms {
    mat4 view;
    mat4 proj;
    float time;
};
layout(set = 0, binding = 1) uniform LightUniforms {
    Light lights[MAX_LIGHTS];
    uint lightCount;
};
layout(set = 0, binding = 2) uniform sampler2D shadowMaps[MAX_LIGHTS];
layout(set = 0, binding = 3) uniform samplerCube cubeShadowMaps[MAX_LIGHTS];

layout(set = 1, binding = 0) uniform sampler2D albedoSampler;
layout(set = 1, binding = 1) uniform sampler2D metallicRoughnessSampler;
layout(set = 1, binding = 2) uniform sampler2D normalSampler;
layout(set = 1, binding = 3) uniform sampler2D displacementSampler;
layout(set = 1, binding = 4) uniform sampler2D emissiveSampler;

layout(set = 1, binding = 5) uniform MaterialFallbacks {
    vec4 albedoValue;
    vec4 emissiveValue;
    float roughnessValue;
    float metallicValue;
};

layout(set = 3, binding = 0) uniform sampler2D environmentMap;

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

float calculatePointShadow(uint lightIdx) {
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

float calculateShadow(uint lightIdx) {
    if (lights[lightIdx].hasShadow == 0) {
        return 1.0;
    }
    if (lights[lightIdx].kind == POINT_LIGHT) {
        return calculatePointShadow(lightIdx);
    }
    vec4 lightSpacePos = lights[lightIdx].viewProj * vec4(position, 1.0);
    vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
    shadowCoord = shadowCoord * 0.5 + 0.5;
    if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
            shadowCoord.z < 0.0 || shadowCoord.z > 1.0) {
        return 1.0;
    }
    return filterPCF(lightIdx, shadowCoord);
}
vec3 calculateLighting(Light light, vec3 viewDir, vec3 albedo) {
    if (light.kind == POINT_LIGHT) {
        vec3 surfaceToLight = normalize(light.position.xyz - position);
        float diff = max(dot(normal, surfaceToLight), 0.0);
        vec3 diffuse = diff * diffuseStrength * light.color.rgb * albedo;
        vec3 specular = vec3(0.0);
        if (diff > 0.0) {
            specular = pow(max(dot(reflect(-surfaceToLight, normal), viewDir), 0.0), shininess) * specularStrength * light.color.rgb;
        }
        float distance = length(position - light.position.xyz);
        // Standard quadratic attenuation
        float constant = 1.0;
        float linear = 0.09;
        float quadratic = 0.032;
        float attenuation = 1.0 / (constant + linear * distance + quadratic * (distance * distance));
        // Hard cutoff at light.radius
        if (distance > light.radius) attenuation = 0.0;
        return (diffuse + specular) * attenuation;
    }
    if (light.kind == DIRECTIONAL_LIGHT) {
        vec3 surfaceToLight = -light.direction.xyz;
        vec3 diffuse = max(dot(normal, surfaceToLight), 0.0) * albedo * diffuseStrength;
        return diffuse;
    }
    if (light.kind == SPOT_LIGHT) {
        vec3 surfaceToLight = normalize(light.position.xyz - position);
        float diff = max(dot(normal, surfaceToLight), 0.0);
        float distance = length(light.position.xyz - position);
        float attenuation = max(0.0, 1.0 - distance / max(0.001, light.radius));
        // Spotlight cone attenuation
        float theta = dot(surfaceToLight, normalize(-light.direction.xyz));
        float epsilon = 0.05; // Soft edge
        float coneAtten = smoothstep(cos(light.angle), cos(light.angle - epsilon), theta);
        vec3 diffuse = diff * albedo * light.color.rgb * diffuseStrength;
        vec3 specular = vec3(0.0);
        if (diff > 0.0) {
            specular = pow(max(dot(reflect(-surfaceToLight, normal), viewDir), 0.0), shininess) * specularStrength * light.color.rgb;
        }
        return (diffuse + specular) * attenuation * coneAtten;
    }
    return vec3(0.0);
}

vec3 brdf(vec3 N, vec3 V, vec3 albedo, float roughness, float metallic) {
    // Cook-Torrance BRDF
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
    // --- PBR Texture Sampling and Fallbacks ---
    vec3 albedo = HAS_ALBEDO_TEXTURE ? texture(albedoSampler, uv).rgb : albedoValue.rgb;
    float metallic = HAS_METALLIC_ROUGHNESS_TEXTURE ? texture(metallicRoughnessSampler, uv).r : metallicValue;
    float roughness = HAS_METALLIC_ROUGHNESS_TEXTURE ? texture(metallicRoughnessSampler, uv).g : roughnessValue;
    vec3 emissive = HAS_EMISSIVE_TEXTURE ? texture(emissiveSampler, uv).rgb : emissiveValue.rgb;

    metallic = clamp(metallic, 0.0, 1.0);
    roughness = clamp(roughness, 0.04, 1.0);
    // --- Normal Mapping ---
    vec3 N = normalize(normal);
    if (HAS_NORMAL_TEXTURE) {
        // Sample normal map in tangent space, remap from [0,1] to [-1,1]
        vec3 tangentNormal = texture(normalSampler, uv).xyz * 2.0 - 1.0;
        // TODO: For correct normal mapping, you should transform tangentNormal by TBN matrix.
        // Here we assume tangent == world for simplicity.
        N = normalize(tangentNormal);
    }

    // --- Displacement Mapping ---
    vec3 displacedPosition = position;
    if (HAS_DISPLACEMENT_TEXTURE) {
        float disp = texture(displacementSampler, uv).r;
        // Displace along the normal direction
        displacedPosition += N * disp;
    }

    // --- View Direction ---
    vec3 V = normalize(cameraPosition - displacedPosition);

    // --- Environment Reflection ---
    vec3 refl = reflect(-V, N);
    float u = atan(refl.z, refl.x) / (2.0 * PI) + 0.5;
    float v = acos(clamp(refl.y, -1.0, 1.0)) / PI;
    vec3 envColor = texture(environmentMap, vec2(u, v)).rgb;

    // --- Ambient + Emissive ---
    vec3 ambient = ambientColor * ambientStrength * albedo + emissive;

    // --- PBR Lighting ---
    vec3 colorOut = ambient + brdf(N, V, albedo, roughness, metallic);

    // --- Simple Environment Reflection (metallic surfaces) ---
    float envStrength = metallic * 0.02;
    colorOut = mix(colorOut, envColor, envStrength);

    outColor = vec4(colorOut, 1.0);
}
