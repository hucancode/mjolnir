// G-buffer fragment shader of PBR materials. Every texture is sampled whatever the material
// has (a missing one is white), then the material picks: sampling stays in uniform control
// flow.
#include "material.slang"
#include "mesh_vertex.slang"

struct GBufferOut {
    float4 normal : SV_Target0;
    float4 albedo : SV_Target1;
    float4 metallic_roughness : SV_Target2;
    float4 emissive : SV_Target3;
}

[shader("fragment")]
GBufferOut fs_main(VertexOut v)
{
    Material material = node_material(v);
    float4 normal_sample = material_texture(material, TEXTURE_NORMAL, v.uv);
    float4 albedo_sample = material_texture(material, TEXTURE_ALBEDO, v.uv);
    float4 mr_sample = material_texture(material, TEXTURE_METALLIC_ROUGHNESS, v.uv);
    float4 emissive_sample = material_texture(material, TEXTURE_EMISSIVE, v.uv);

    float3 n = normalize(v.normal);
    if (material.normal_index != NO_TEXTURE) {
        float2 n_xy = normal_sample.xy * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        float3 t = normalize(v.tangent.xyz);
        float3 b = normalize(cross(n, t)) * v.tangent.w;
        n = normalize(t * n_xy.x + b * n_xy.y + n * n_z);
    }
    GBufferOut o;
    o.normal = float4(n * 0.5 + 0.5, 1.0);
    if (material.albedo_index != NO_TEXTURE) {
        o.albedo = albedo_sample * material.base_color_factor;
    } else {
        o.albedo = v.color * material.base_color_factor;
    }
    float metallic = material.metallic_value;
    float roughness = material.roughness_value;
    if (material.metallic_roughness_index != NO_TEXTURE) {
        metallic *= mr_sample.b;
        roughness *= mr_sample.g;
    }
    o.metallic_roughness = float4(metallic, roughness, 0.0, 1.0);
    float3 emissive = float3(material.emissive_value);
    if (material.emissive_index != NO_TEXTURE) {
        emissive = emissive_sample.rgb * material.emissive_value;
    }
    o.emissive = float4(emissive, 1.0);
    return o;
}
