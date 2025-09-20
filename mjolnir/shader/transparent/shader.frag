#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const bool SKINNED = false;
layout(constant_id = 1) const bool ALBEDO_TEXTURE = false;
layout(constant_id = 2) const bool METALLIC_ROUGHNESS_TEXTURE = false;
layout(constant_id = 3) const bool NORMAL_TEXTURE = false;
layout(constant_id = 4) const bool EMISSIVE_TEXTURE = false;

layout(location = 0) in vec3 inWorldPos;
layout(location = 1) in vec3 inNormal;
layout(location = 2) in vec2 inTexCoord;
layout(location = 3) in vec4 inColor;
layout(location = 4) in mat3 inTBN;

layout(location = 0) out vec4 outColor;

const uint SAMPLER_NEAREST_CLAMP = 0;
const uint SAMPLER_LINEAR_CLAMP  = 1;
const uint SAMPLER_NEAREST_REPEAT = 2;
const uint SAMPLER_LINEAR_REPEAT  = 3;

struct Camera {
    mat4 view;
    mat4 projection;
    vec2 viewport_size;
    float camera_near;
    float camera_far;
    vec3 camera_position;
    float padding[9];
};

layout(set = 0, binding = 0) readonly buffer CameraBuffer {
    Camera cameras[];
} camera_buffer;

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];
layout(set = 1, binding = 2) uniform textureCube cube_textures[];

struct NodeData {
    uint vertex_offset;
    uint index_offset;
    uint index_count;
    uint material_index;
    uint skin_vertex_offset;
    uint bone_matrix_offset;
    uint flags;
    uint padding;
};

struct MaterialData {
    vec4 base_color_factor;
    uint albedo_texture_index;
    uint metallic_texture_index;
    uint normal_texture_index;
    uint emissive_texture_index;
    uint occlusion_texture_index;
    uint material_type;
    uint features_mask;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    float padding;
};

layout(set = 3, binding = 1) readonly buffer NodeBuffer {
    NodeData nodes[];
};

layout(set = 3, binding = 2) readonly buffer MaterialBuffer {
    MaterialData materials[];
};

layout(push_constant) uniform PushConstants {
    uint node_index;
    uint camera_index;
};

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
    float r = roughness + 1.0;
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
    MaterialData material = materials[node.material_index];

    vec4 albedo;
    if (ALBEDO_TEXTURE) {
        albedo = texture(
            sampler2D(textures[material.albedo_texture_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord);
    } else {
        albedo = inColor * material.base_color_factor;
    }
    if (albedo.a < 0.001) {
        discard;
    }

    float metallic;
    float roughness;
    if (METALLIC_ROUGHNESS_TEXTURE) {
        vec4 mr = texture(
            sampler2D(textures[material.metallic_texture_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord);
        metallic = mr.b * material.metallic_value;
        roughness = mr.g * material.roughness_value;
    } else {
        metallic = material.metallic_value;
        roughness = material.roughness_value;
    }

    vec3 emissive;
    if (EMISSIVE_TEXTURE) {
        vec3 emissive_sample = texture(
            sampler2D(textures[material.emissive_texture_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord).rgb;
        emissive = emissive_sample * material.emissive_value;
    } else {
        emissive = vec3(material.emissive_value);
    }

    vec3 N;
    if (NORMAL_TEXTURE) {
        vec2 encoded_normal = texture(
            sampler2D(textures[material.normal_texture_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord).xy;
        vec2 n_xy = encoded_normal * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        vec3 normalSample = vec3(n_xy, n_z);
        N = normalize(inTBN * normalSample);
    } else {
        N = normalize(inNormal);
    }

    Camera camera = camera_buffer.cameras[camera_index];
    vec3 cameraPos = camera.camera_position;
    vec3 V = normalize(cameraPos - inWorldPos);

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
