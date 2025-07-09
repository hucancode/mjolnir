#version 450
#extension GL_EXT_nonuniform_qualifier : require
// Specialization constants
layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool ALBEDO_TEXTURE = false;
layout(constant_id = 2) const bool METALLIC_ROUGHNESS_TEXTURE = false;
layout(constant_id = 3) const bool NORMAL_TEXTURE = false;
layout(constant_id = 4) const bool EMISSIVE_TEXTURE = false;

// Input from vertex shader
layout(location = 0) in vec3 inWorldPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec4 inColor;
layout(location = 4) in mat3 inTBN;

// Output
layout(location = 0) out vec4 outColor;

// Constants
const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT = 3;

layout(set = 0, binding = 0) uniform CameraUniform {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec2 padding;
    vec3 camera_position;
    float padding2;
} camera;


// textures and samplers set = 1
layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

// Push constants
layout(push_constant) uniform PushConstant {
    mat4 world;            // 64 bytes
    uint bone_matrix_offset; // 4
    uint albedo_index;     // 4
    uint metallic_roughness_index; // 4
    uint normal_index;     // 4
    uint emissive_index;   // 4
    float metallic_value;  // 4
    float roughness_value; // 4
    float emissive_value;  // 4
};

// Constants
const float PI = 3.14159265359;
const float EPSILON = 0.00001;
const float MAX_REFLECTION_LOD = 9.0;
const float AMBIENT_STRENGTH = 3.0;

// Calculate normal distribution function
float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH2 = NdotH * NdotH;

    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;

    return a2 / max(denom, EPSILON);
}

// Calculate geometry function
float geometrySchlickGGX(float NdotV, float roughness) {
    float r = (roughness + 1.0);
    float k = (r * r) / 8.0;

    float denom = NdotV * (1.0 - k) + k;

    return NdotV / max(denom, EPSILON);
}

float geometrySmith(float NdotV, float NdotL, float roughness) {
    float ggx1 = geometrySchlickGGX(NdotV, roughness);
    float ggx2 = geometrySchlickGGX(NdotL, roughness);

    return ggx1 * ggx2;
}

// Calculate Fresnel equation
vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(max(1.0 - cosTheta, 0.0), 5.0);
}

vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(max(1.0 - cosTheta, 0.0), 5.0);
}

void main() {
    // Sample material textures
    vec4 albedo;
    if (ALBEDO_TEXTURE) {
        albedo = texture(sampler2D(textures[albedo_index], samplers[SAMPLER_LINEAR_REPEAT]), inTexCoord);
    } else {
        albedo = inColor;
    }

    float metallic;
    float roughness;
    if (METALLIC_ROUGHNESS_TEXTURE) {
        vec4 mr = texture(sampler2D(textures[metallic_roughness_index], samplers[SAMPLER_LINEAR_REPEAT]), inTexCoord);
        metallic = mr.b * metallic_value;
        roughness = mr.g * roughness_value;
    } else {
        metallic = metallic_value;
        roughness = roughness_value;
    }

    vec3 emissive;
    if (EMISSIVE_TEXTURE) {
        emissive = texture(sampler2D(textures[emissive_index], samplers[SAMPLER_LINEAR_REPEAT]), inTexCoord).rgb * emissive_value;
    } else {
        emissive = vec3(emissive_value);
    }

    // Calculate normal
    vec3 N;
    if (NORMAL_TEXTURE) {
        // Sample tangent-space normal from normal map
        vec2 n_xy = texture(sampler2D(textures[normal_index], samplers[SAMPLER_LINEAR_REPEAT]), inTexCoord).xy * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        vec3 normalSample = vec3(n_xy, n_z);
        N = normalize(inTBN * normalSample);
    } else {
        N = normalize(inNormal);
    }

    // Calculate camera position from inverse view matrix
    mat4 invView = inverse(camera.view);
    vec3 cameraPos = invView[3].xyz;
    vec3 V = normalize(cameraPos - inWorldPos);
    vec3 R = reflect(-V, N);

    // Calculate reflectance at normal incidence
    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo.rgb, metallic);

    // Calculate reflection
    vec3 F = fresnelSchlickRoughness(max(dot(N, V), 0.0), F0, roughness);

    vec3 kS = F;
    vec3 kD = (1.0 - kS) * (1.0 - metallic);

    // Calculate ambient lighting - no environment map in this renderer
    // This is a simplified approach for transparent objects
    vec3 irradiance = vec3(0.3, 0.3, 0.3); // Ambient light
    vec3 diffuse = irradiance * albedo.rgb;

    // Simplified specular for transparent objects
    vec3 prefilteredColor = vec3(0.1, 0.1, 0.1);
    vec2 brdf = vec2(1.0, 0.0);
    vec3 specular = prefilteredColor * (F * brdf.x + brdf.y);

    // Combine lighting components
    vec3 ambient = (kD * diffuse + specular) * AMBIENT_STRENGTH + emissive;

    // Final color
    outColor = vec4(ambient, albedo.a);
}
