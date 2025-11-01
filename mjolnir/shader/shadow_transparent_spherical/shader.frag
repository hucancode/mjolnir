#version 450
#extension GL_EXT_nonuniform_qualifier : require

layout(constant_id = 0) const uint MAX_TEXTURES = 1u;
layout(constant_id = 4) const uint SAMPLER_LINEAR_CLAMP = 1u;

layout(location = 0) in vec3 fragWorldPos;
layout(location = 1) in flat uint fragInstanceIndex;
layout(location = 2) in vec2 fragTexCoord;

layout(location = 0) out vec4 outColor;

struct SphericalCamera {
    mat4 projection;
    vec4 position; // center.xyz, radius in w
    vec2 near_far;
    vec2 _padding;
};

layout(set = 0, binding = 0) readonly buffer SphericalCameraBuffer {
    SphericalCamera cameras[];
};

layout(set = 1, binding = 0) uniform texture2D textures[];
layout(set = 1, binding = 1) uniform sampler samplers[];

struct MaterialData {
    vec4 base_color_factor;
    uint base_color_texture;
    uint metallic_roughness_texture;
    uint normal_texture;
    uint emissive_texture;
    float metallic_factor;
    float roughness_factor;
    float alpha_cutoff;
    uint flags;
};

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

layout(push_constant) uniform PushConstants {
    uint camera_index;
};

void main() {
    NodeData node = nodes[fragInstanceIndex];
    MaterialData material = materials[node.material_id];

    // Sample base color texture
    vec4 albedo = material.base_color_factor;
    if (material.base_color_texture < MAX_TEXTURES) {
        albedo *= texture(sampler2D(textures[material.base_color_texture], samplers[SAMPLER_LINEAR_CLAMP]), fragTexCoord);
    }

    // Output color modulates light passing through
    // Alpha controls transparency: 0 = fully transparent, 1 = fully opaque
    // The color represents the tint applied to light passing through
    outColor = vec4(albedo.rgb, 1.0 - albedo.a);
}
