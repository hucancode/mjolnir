// Transparent: forward-shaded with a fixed ambient (no IBL), alpha-blended in the material's
// alpha. Every texture is sampled whatever the material has, then the material picks, so
// sampling happens before the discard and stays in uniform control flow.
#include "material.slang"
#include "mesh_vertex.slang"

static const float AMBIENT_STRENGTH = 3.0;

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
    Material material = node_material(v);
    float4 albedo_sample = material_texture(material, TEXTURE_ALBEDO, v.uv);
    float4 mr_sample = material_texture(material, TEXTURE_METALLIC_ROUGHNESS, v.uv);
    float4 normal_sample = material_texture(material, TEXTURE_NORMAL, v.uv);
    float4 emissive_sample = material_texture(material, TEXTURE_EMISSIVE, v.uv);

    float4 albedo = v.color * material.base_color_factor;
    if (material.albedo_index != NO_TEXTURE) {
        albedo = albedo_sample * material.base_color_factor;
    }
    if (albedo.a < 0.001) {
        discard;
    }
    float metallic = material.metallic_factor;
    float roughness = material.roughness_factor;
    if (material.metallic_roughness_index != NO_TEXTURE) {
        metallic = mr_sample.b * material.metallic_factor;
        roughness = mr_sample.g * material.roughness_factor;
    }
    float3 emissive = float3(material.emissive_factor);
    if (material.emissive_index != NO_TEXTURE) {
        emissive = emissive_sample.rgb * material.emissive_factor;
    }
    float3 n = normalize(v.normal);
    if (material.normal_index != NO_TEXTURE) {
        float2 n_xy = normal_sample.xy * 2.0 - 1.0;
        float n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        float3 t = normalize(v.tangent.xyz);
        float3 b = normalize(cross(n, t)) * v.tangent.w;
        n = normalize(t * n_xy.x + b * n_xy.y + n * n_z);
    }
    float3 e = normalize(camera_view().position.xyz - v.position);
    float3 f0 = lerp(float3(0.04), albedo.rgb, metallic);
    float3 f = fresnel_schlick_roughness(max(dot(n, e), 0.0), f0, roughness);
    float3 kd = (float3(1.0) - f) * (1.0 - metallic);
    float3 irradiance = float3(0.3);
    float3 diffuse = irradiance * albedo.rgb;
    float3 prefiltered = float3(0.1);
    float2 brdf = float2(1.0, 0.0);
    float3 specular = prefiltered * (f * brdf.x + brdf.y);
    float3 ambient = (kd * diffuse + specular) * AMBIENT_STRENGTH + emissive;
    return float4(ambient, albedo.a);
}
