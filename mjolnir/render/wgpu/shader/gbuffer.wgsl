// G-buffer fragment shader of PBR materials. Every texture is sampled whatever the material
// has (a missing one is bound white), then the material picks: sampling stays in uniform
// control flow.

@group(1) @binding(0) var albedo_texture: texture_2d<f32>;
@group(1) @binding(1) var metallic_roughness_texture: texture_2d<f32>;
@group(1) @binding(2) var normal_texture: texture_2d<f32>;
@group(1) @binding(3) var emissive_texture: texture_2d<f32>;

struct GBufferOut {
    @location(0) normal: vec4f,
    @location(1) albedo: vec4f,
    @location(2) metallic_roughness: vec4f,
    @location(3) emissive: vec4f,
}

@fragment
fn fs_main(in: VertexOut) -> GBufferOut {
    let material = materials[nodes[in.node_index].material_id];
    let normal_sample = textureSample(normal_texture, linear_repeat, in.uv);
    let albedo_sample = textureSample(albedo_texture, linear_repeat, in.uv);
    let mr_sample = textureSample(metallic_roughness_texture, linear_repeat, in.uv);
    let emissive_sample = textureSample(emissive_texture, linear_repeat, in.uv);

    var n = normalize(in.normal);
    if (material.normal_index != NO_TEXTURE) {
        let n_xy = normal_sample.xy * 2.0 - 1.0;
        let n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        let t = normalize(in.tangent.xyz);
        let b = normalize(cross(n, t)) * in.tangent.w;
        n = normalize(mat3x3f(t, b, n) * vec3f(n_xy, n_z));
    }
    var out: GBufferOut;
    out.normal = vec4f(n * 0.5 + 0.5, 1.0);
    if (material.albedo_index != NO_TEXTURE) {
        out.albedo = albedo_sample * material.base_color_factor;
    } else {
        out.albedo = in.color * material.base_color_factor;
    }
    var metallic = material.metallic_value;
    var roughness = material.roughness_value;
    if (material.metallic_roughness_index != NO_TEXTURE) {
        metallic *= mr_sample.b;
        roughness *= mr_sample.g;
    }
    out.metallic_roughness = vec4f(metallic, roughness, 0.0, 1.0);
    var emissive = vec3f(material.emissive_value);
    if (material.emissive_index != NO_TEXTURE) {
        emissive = emissive_sample.rgb * material.emissive_value;
    }
    out.emissive = vec4f(emissive, 1.0);
    return out;
}
