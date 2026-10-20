// A user material shader: cel shading under the scene's sun. Reads its material's params as
//   base_color_factor  the lit color (times the albedo texture, if any)
//   params[0].x        the number of light bands
//   params[0].y        the rim light strength
//   params[0].z        how dark the unlit band is (0 = black, 1 = no shading)
#include "material.slang"

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
    Material m = node_material(v);
    float3 albedo = (material_texture(m, TEXTURE_ALBEDO, v.uv) * m.base_color_factor).rgb;
    float3 n = normalize(v.normal);
    View view = camera_view();
    float3 e = normalize(view.position.xyz - v.position);

    float bands = max(m.params[0].x, 1.0);
    float ndl = max(dot(n, view.sun_direction.xyz), 0.0);
    float light = min(floor(ndl * bands + 0.5) / bands, 1.0);
    float3 color = albedo * view.sun_radiance.rgb * lerp(m.params[0].z, 1.0, light);

    float rim = step(0.6, 1.0 - max(dot(n, e), 0.0)) * step(0.1, ndl);
    color += rim * m.params[0].y;
    return float4(color, 1.0);
}
