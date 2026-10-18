#version 450
// A user material shader: cel shading under the scene's sun. Reads its material's params as
//   base_color_factor  the lit color (times the albedo texture, if any)
//   params[0].x        the number of light bands
//   params[0].y        the rim light strength
//   params[0].z        how dark the unlit band is (0 = black, 1 = no shading)

#include "material.glsl"

void main() {
    Material m = node_material();
    vec3 albedo = (sample_texture(m.albedo_index, in_uv) * m.base_color_factor).rgb;
    vec3 n = normalize(in_normal);
    View view = camera_view();
    vec3 v = normalize(view.position.xyz - in_position);

    float bands = max(m.params[0].x, 1.0);
    float ndl = max(dot(n, view.sun_direction.xyz), 0.0);
    float light = min(floor(ndl * bands + 0.5) / bands, 1.0);
    vec3 color = albedo * view.sun_radiance.rgb * mix(m.params[0].z, 1.0, light);

    float rim = step(0.6, 1.0 - max(dot(n, v), 0.0)) * step(0.1, ndl);
    color += rim * m.params[0].y;
    out_color = vec4(color, 1.0);
}
