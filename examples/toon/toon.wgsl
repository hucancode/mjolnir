// A user material shader: cel shading under the scene's sun. Follows common.wgsl, mesh.wgsl and
// material_custom.wgsl (render.material_shader_create). Reads its material's params as
//   base_color_factor  the lit color (times the albedo texture, if any)
//   params[0].x        the number of light bands
//   params[0].y        the rim light strength
//   params[0].z        how dark the unlit band is (0 = black, 1 = no shading)

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let m = node_material(in);
    let albedo = (textureSample(albedo_texture, linear_repeat, in.uv) * m.base_color_factor).rgb;
    let n = normalize(in.normal);
    let view = views[u.camera_index];
    let v = normalize(view.position.xyz - in.position);

    let bands = max(m.params[0].x, 1.0);
    let ndl = max(dot(n, view.sun_direction.xyz), 0.0);
    let light = min(floor(ndl * bands + 0.5) / bands, 1.0);
    var color = albedo * view.sun_radiance.rgb * mix(m.params[0].z, 1.0, light);

    let rim = step(0.6, 1.0 - max(dot(n, v), 0.0)) * step(0.1, ndl);
    color += rim * m.params[0].y;
    return vec4f(color, 1.0);
}
