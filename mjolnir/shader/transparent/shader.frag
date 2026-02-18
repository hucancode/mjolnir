#version 450
#extension GL_EXT_nonuniform_qualifier : require

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

const uint FEATURE_ALBEDO_TEXTURE = 1u << 0;
const uint FEATURE_METALLIC_ROUGHNESS_TEXTURE = 1u << 1;
const uint FEATURE_NORMAL_TEXTURE = 1u << 2;
const uint FEATURE_EMISSIVE_TEXTURE = 1u << 3;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_extent;
    float near;
    float far;
    vec4 position;
    vec4 frustum_planes[6];
};

struct MaterialData {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint features;
    vec4 base_color_factor;
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

layout(set = 3, binding = 0) readonly buffer MaterialBuffer {
    MaterialData materials[];
};

struct NodeData {
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
};

layout(set = 5, binding = 0) readonly buffer NodeBuffer {
    NodeData nodes[];
};

// Push constant budget: 80 bytes
layout(push_constant) uniform PushConstants {
    uint camera_index;
};

layout(location = 0) in vec3 inWorldPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec4 inColor;
layout(location = 4) in mat3 inTBN;
layout(location = 7) flat in uint node_index;

layout(location = 0) out vec4 outColor;

const float PI = 3.14159265359;
const float EPSILON = 0.00001;
const float MAX_REFLECTION_LOD = 9.0;
const float AMBIENT_STRENGTH = 3.0;

float distributionGGX(float NdotH, float roughness) {
    float a = roughness * roughness;
    float a2 = a * a;
    float NdotH2 = NdotH * NdotH;
    float denom = (NdotH2 * (a2 - 1.0) + 1.0);
    denom = PI * denom * denom;
    return a2 / max(denom, EPSILON);
}

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

vec3 fresnelSchlick(float cosTheta, vec3 F0) {
    return F0 + (1.0 - F0) * pow(max(1.0 - cosTheta, 0.0), 5.0);
}

vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(max(1.0 - cosTheta, 0.0), 5.0);
}

void main() {
    NodeData node = nodes[node_index];
    MaterialData material = materials[node.material_id];
    bool has_albedo = (material.features & FEATURE_ALBEDO_TEXTURE) != 0u;
    bool has_mr = (material.features & FEATURE_METALLIC_ROUGHNESS_TEXTURE) != 0u;
    bool has_normal = (material.features & FEATURE_NORMAL_TEXTURE) != 0u;
    bool has_emissive = (material.features & FEATURE_EMISSIVE_TEXTURE) != 0u;

    vec4 albedo;
    if (has_albedo) {
        albedo = texture(
            sampler2D(textures[material.albedo_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord
        );
    } else {
        albedo = inColor;
    }
    if (albedo.a < 0.001) {
        discard;
    }

    float metallic;
    float roughness;
    if (has_mr) {
        vec4 mr = texture(
            sampler2D(
                textures[material.metallic_roughness_index],
                samplers[SAMPLER_LINEAR_REPEAT]
            ),
            inTexCoord
        );
        metallic = mr.b * material.metallic_value;
        roughness = mr.g * material.roughness_value;
    } else {
        metallic = material.metallic_value;
        roughness = material.roughness_value;
    }

    vec3 emissive;
    if (has_emissive) {
        emissive = texture(
            sampler2D(textures[material.emissive_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord
        ).rgb * material.emissive_value;
    } else {
        emissive = vec3(material.emissive_value);
    }

    vec3 N;
    if (has_normal) {
        vec2 n_xy = texture(
            sampler2D(textures[material.normal_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord
        ).xy * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        vec3 normalSample = vec3(n_xy, n_z);
        N = normalize(inTBN * normalSample);
    } else {
        N = normalize(inNormal);
    }

    Camera camera = camera_buffer.cameras[camera_index];
    mat4 invView = inverse(camera.view);
    vec3 cameraPos = invView[3].xyz;
    vec3 V = normalize(cameraPos - inWorldPos);
    vec3 R = reflect(-V, N);

    vec3 F0 = vec3(0.04);
    F0 = mix(F0, albedo.rgb, metallic);
    vec3 F = fresnelSchlickRoughness(max(dot(N, V), 0.0), F0, roughness);

    vec3 kS = F;
    vec3 kD = (1.0 - kS) * (1.0 - metallic);

    vec3 irradiance = vec3(0.3, 0.3, 0.3);
    vec3 diffuse = irradiance * albedo.rgb;

    vec3 prefilteredColor = vec3(0.1, 0.1, 0.1);
    vec2 brdf = vec2(1.0, 0.0);
    vec3 specular = prefilteredColor * (F * brdf.x + brdf.y);
    vec3 ambient = (kD * diffuse + specular) * AMBIENT_STRENGTH + emissive;
    outColor = vec4(ambient.rgb, albedo.a);
}
