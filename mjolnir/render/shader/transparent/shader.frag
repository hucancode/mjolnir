#version 450
#extension GL_EXT_nonuniform_qualifier : require

const uint SAMPLER_NEAREST_CLAMP = 0u;
const uint SAMPLER_LINEAR_CLAMP = 1u;
const uint SAMPLER_NEAREST_REPEAT = 2u;
const uint SAMPLER_LINEAR_REPEAT = 3u;

// texture index of a material slot without a texture
const uint NO_TEXTURE = 0xFFFFFFFFu;

struct View {
    mat4 view;
    mat4 projection;
    mat4 view_projection;
    mat4 inv_view_projection; // rebuilds world positions from depth
    vec4 planes[6]; // normalized, pointing inward
    vec4 position;
    vec2 extent;
    float near;
    float far;
    uint attachments[6]; // this frame's bindless images, by AttachmentType
    uint pyramid; // bindless depth pyramid
    uint occlusion_mask; // bit t: material type t is tested against the pyramid
    uint list_stride;
    uint type_mask; // bit t: material type t is drawn
    uint require_flags; // node flags a drawn node has
    uint instance_tag; // OR-ed into first_instance above the node index
    uint layer;
    uint draw_list; // bindless draw lists the view appends to
    uint list_capacity; // draws per list
    uint _pad0;
};

struct MaterialData {
    uint albedo_index;
    uint metallic_roughness_index;
    uint normal_index;
    uint emissive_index;
    float metallic_value;
    float roughness_value;
    float emissive_value;
    uint _pad;
    vec4 base_color_factor;
    uint frame_columns;
    uint frame_rows;
    uint frame_index;
    uint _pad0;
};

layout(set = 0, binding = 0) readonly buffer ViewBuffer {
    View views[];
};

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

layout(set = 0, binding = 3) readonly buffer MaterialBuffer {
    MaterialData materials[];
};

struct NodeData {
    mat4 world_matrix;
    uint material_id;
    uint mesh_id;
    uint attachment_data_index;
    uint flags;
};

layout(set = 0, binding = 1) readonly buffer NodeBuffer {
    NodeData nodes[];
};

// Push constant budget: 80 bytes
layout(push_constant) uniform PushConstants {
    uint camera_index;
};

layout(location = 0) in vec3 inWorldPos;
layout(location = 1) in vec4 inColor;
layout(location = 2) in vec3 inNormal;
layout(location = 3) in vec2 inTexCoord;
layout(location = 4) in vec4 inTangent;
layout(location = 5) flat in uint node_index;

layout(location = 0) out vec4 outColor;

const float AMBIENT_STRENGTH = 3.0;

vec3 fresnelSchlickRoughness(float cosTheta, vec3 F0, float roughness) {
    return F0 + (max(vec3(1.0 - roughness), F0) - F0) * pow(max(1.0 - cosTheta, 0.0), 5.0);
}

void main() {
    NodeData node = nodes[node_index];
    MaterialData material = materials[node.material_id];
    bool has_albedo = material.albedo_index != NO_TEXTURE;
    bool has_mr = material.metallic_roughness_index != NO_TEXTURE;
    bool has_normal = material.normal_index != NO_TEXTURE;
    bool has_emissive = material.emissive_index != NO_TEXTURE;

    vec4 albedo;
    if (has_albedo) {
        albedo = texture(
            sampler2D(textures[material.albedo_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord
        ) * material.base_color_factor;
    } else {
        albedo = inColor * material.base_color_factor;
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

    vec3 N = normalize(inNormal);
    if (has_normal) {
        vec2 n_xy = texture(
            sampler2D(textures[material.normal_index], samplers[SAMPLER_LINEAR_REPEAT]),
            inTexCoord
        ).xy * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        vec3 normalSample = vec3(n_xy, n_z);
        vec3 T = normalize(inTangent.xyz);
        vec3 B = normalize(cross(N, T)) * inTangent.w;
        N = normalize(mat3(T, B, N) * normalSample);
    }

    View camera = views[camera_index];
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
