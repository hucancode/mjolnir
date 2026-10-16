// A user material shader: cel shading. Follows common.wgsl, mesh.wgsl and
// material_custom.wgsl (render.material_shader_create). Reads the material's fields as
//   base_color_factor  the lit color (times the albedo texture, if any)
//   frame_columns      the number of light bands
//   emissive_value     the rim light strength
//   metallic_value     how dark the unlit band is (0 = black, 1 = no shading)

const SUN_DIRECTION = vec3f(-0.4, 0.8, 0.45);

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let m = node_material(in);
    let albedo = (textureSample(albedo_texture, linear_repeat, in.uv) * m.base_color_factor).rgb;
    let n = normalize(in.normal);
    let v = normalize(views[u.camera_index].position.xyz - in.position);

    let bands = f32(max(m.frame_columns, 1u));
    let ndl = max(dot(n, normalize(SUN_DIRECTION)), 0.0);
    let light = min(floor(ndl * bands + 0.5) / bands, 1.0);
    var color = albedo * mix(m.metallic_value, 1.0, light);

    let rim = step(0.6, 1.0 - max(dot(n, v), 0.0)) * step(0.1, ndl);
    color += rim * m.emissive_value;
    return vec4f(color, 1.0);
}
