// Transparent: forward-shaded with a fixed ambient (no IBL), alpha-blended in the material's
// alpha. Every texture is sampled whatever the material has, then the material picks, so
// sampling happens before the discard and stays in uniform control flow.

@group(1) @binding(0) var albedo_texture: texture_2d<f32>;
@group(1) @binding(1) var metallic_roughness_texture: texture_2d<f32>;
@group(1) @binding(2) var normal_texture: texture_2d<f32>;
@group(1) @binding(3) var emissive_texture: texture_2d<f32>;

const AMBIENT_STRENGTH: f32 = 3.0;

fn fresnel_schlick_roughness(cos_theta: f32, f0: vec3f, roughness: f32) -> vec3f {
    return f0 + (max(vec3f(1.0 - roughness), f0) - f0) * pow(max(1.0 - cos_theta, 0.0), 5.0);
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let material = materials[nodes[in.node_index].material_id];
    let albedo_sample = textureSample(albedo_texture, linear_repeat, in.uv);
    let mr_sample = textureSample(metallic_roughness_texture, linear_repeat, in.uv);
    let normal_sample = textureSample(normal_texture, linear_repeat, in.uv);
    let emissive_sample = textureSample(emissive_texture, linear_repeat, in.uv);

    var albedo = in.color * material.base_color_factor;
    if (material.albedo_index != NO_TEXTURE) {
        albedo = albedo_sample * material.base_color_factor;
    }
    if (albedo.a < 0.001) {
        discard;
    }
    var metallic = material.metallic_value;
    var roughness = material.roughness_value;
    if (material.metallic_roughness_index != NO_TEXTURE) {
        metallic = mr_sample.b * material.metallic_value;
        roughness = mr_sample.g * material.roughness_value;
    }
    var emissive = vec3f(material.emissive_value);
    if (material.emissive_index != NO_TEXTURE) {
        emissive = emissive_sample.rgb * material.emissive_value;
    }
    var n = normalize(in.normal);
    if (material.normal_index != NO_TEXTURE) {
        let n_xy = normal_sample.xy * 2.0 - 1.0;
        let n_z = sqrt(clamp(1.0 - dot(n_xy, n_xy), 0.0, 1.0));
        let t = normalize(in.tangent.xyz);
        let b = normalize(cross(n, t)) * in.tangent.w;
        n = normalize(mat3x3f(t, b, n) * vec3f(n_xy, n_z));
    }
    let v = normalize(views[u.camera_index].position.xyz - in.position);
    let f0 = mix(vec3f(0.04), albedo.rgb, metallic);
    let f = fresnel_schlick_roughness(max(dot(n, v), 0.0), f0, roughness);
    let kd = (vec3f(1.0) - f) * (1.0 - metallic);
    let irradiance = vec3f(0.3);
    let diffuse = irradiance * albedo.rgb;
    let prefiltered = vec3f(0.1);
    let brdf = vec2f(1.0, 0.0);
    let specular = prefiltered * (f * brdf.x + brdf.y);
    let ambient = (kd * diffuse + specular) * AMBIENT_STRENGTH + emissive;
    return vec4f(ambient, albedo.a);
}
