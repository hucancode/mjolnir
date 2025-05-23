#version 450

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool HAS_TEXTURE = false;
layout(constant_id = 2) const bool IS_LIT = false;
layout(constant_id = 3) const bool CAN_RECEIVE_SHADOW = false;

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
layout(set = 1, binding = 1) uniform sampler2D metalicSampler;
layout(set = 1, binding = 2) uniform sampler2D roughnessSampler;

layout(location = 0) in vec3 position;
layout(location = 1) in vec4 color;
layout(location = 2) in vec3 normal;
layout(location = 3) in vec2 uv;
layout(location = 0) out vec4 outColor;

const vec3 ambientColor = vec3(0.0, 0.5, 1.0);
const float ambientStrength = 0.05;
const float specularStrength = 0.5;
const float shininess = 8.0;
const float diffuseStrength = 0.5;

float textureProj(uint lightIdx, vec3 shadowCoord) {
    vec3 surfaceToLight = lights[lightIdx].position.xyz - position;
    float currentDepth = shadowCoord.z;
    float shadowDepth = texture(shadowMaps[lightIdx], shadowCoord.xy).r;
    float bias = max(0.1 * (1.0 - dot(normalize(normal), normalize(surfaceToLight))), 0.05);
    bool inShadow = currentDepth > shadowDepth + bias;
    return inShadow ? 0.1 : 1.0;
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
    vec3 surfaceToLight = lights[lightIdx].position.xyz - position;
    float currentDepth = length(surfaceToLight);
    float shadowDepth = texture(cubeShadowMaps[lightIdx], normalize(-surfaceToLight)).r;
    // Reconstruct linear depth from perspective depth
    float near = 0.1;
    float far = lights[lightIdx].radius;
    float z_n = 2.0 * shadowDepth - 1.0;
    float shadowDepthLinear = (2.0 * near * far) / (far + near - z_n * (far - near));
    float bias = max(0.1 * (1.0 - dot(normal, normalize(surfaceToLight))), 0.05);
    bool inShadow = currentDepth > shadowDepthLinear + 1;
    return inShadow ? 0.1 : 1.0;
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
        float attenuation = max(0.0, 1.0 - distance / max(0.001, light.radius));
        return (diffuse + specular) * pow(attenuation, 2.0);
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

void main() {
    vec3 cameraPosition = -inverse(view)[3].xyz;
    vec3 albedo = HAS_TEXTURE ? texture(albedoSampler, uv).rgb : color.rgb;
    vec3 viewDir = normalize(cameraPosition.xyz - position);
    vec3 result = ambientColor * ambientStrength;
    if (IS_LIT) {
        for (int i = 0; i < min(lightCount, MAX_LIGHTS); i++) {
            float shadow = calculateShadow(i);
            result += shadow * calculateLighting(lights[i], viewDir, albedo);
        }
    }
    result *= albedo;
    outColor = vec4(result, 1.0);
}
