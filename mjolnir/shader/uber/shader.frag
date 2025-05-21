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
    float dist = texture(shadowMaps[lightIdx], shadowCoord.xy).r;
    if (dist < shadowCoord.z) {
        return 0.1;
    }
    return 1.0;
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
float calculatePointShadow(uint lightIdx, vec3 fragPos) {
    // Sample cube shadow map for point light
    float shadow = 0.0;
    vec3 lightToFrag = fragPos - lights[lightIdx].position.xyz;
    float currentDepth = length(lightToFrag);
    float bias = 0.01;
    float shadowDepth = texture(cubeShadowMaps[lightIdx], lightToFrag).r * lights[lightIdx].radius;
    if (currentDepth - bias > shadowDepth) {
        shadow = 0.1;
    } else {
        shadow = 1.0;
    }
    return shadow;
}
float calculateShadow(uint lightIdx, vec3 worldPos) {
    if (lights[lightIdx].hasShadow == 0) {
        return 1.0;
    }
    if (lights[lightIdx].kind == POINT_LIGHT) {
        return calculatePointShadow(lightIdx, worldPos);
    }
    vec4 lightSpacePos = lights[lightIdx].viewProj * vec4(worldPos, 1.0);
    vec3 shadowCoord = lightSpacePos.xyz / lightSpacePos.w;
    shadowCoord = shadowCoord * 0.5 + 0.5;
    if (shadowCoord.x < 0.0 || shadowCoord.x > 1.0 ||
            shadowCoord.y < 0.0 || shadowCoord.y > 1.0 ||
            shadowCoord.z < 0.0 || shadowCoord.z > 1.0) {
        return 1.0;
    }
    return filterPCF(lightIdx, shadowCoord);
}
vec3 calculateLighting(Light light, vec3 normal, vec3 position, vec3 viewDir, vec3 albedo) {
    if (light.kind == POINT_LIGHT) {
        vec3 surfaceToLight = normalize(light.position.xyz - position);
        vec3 diffuse = max(0.0, dot(surfaceToLight, normal)) * diffuseStrength * light.color.rgb;
        vec3 specular = pow(max(0.0, dot(reflect(-surfaceToLight, normal), viewDir)), shininess) * specularStrength * light.color.rgb;
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
        light.angle = PI * 0.1;
        vec3 lightToSurface = normalize(position - light.position.xyz);
        float delta = abs(acos(dot(lightToSurface, light.direction.xyz)));
        if (delta > PI) {
            delta -= PI * 2;
        }
        return vec3(smoothstep(0.0, 0.85, max(0.0, 1.0 - delta / light.angle)));
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
            float shadow = calculateShadow(i, position);
            result += calculateLighting(lights[i], normalize(normal), position, viewDir, albedo) * shadow;
        }
    }
    result *= albedo;
    outColor = vec4(result, 1.0);
}
