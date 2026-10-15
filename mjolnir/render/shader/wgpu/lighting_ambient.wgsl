// The ambient light: image-based lighting, emissive, and the skybox where nothing was drawn.
// Alpha 0 keeps the cleared alpha under the additive blend.

fn prefilter_max_lod() -> f32 {
    return f32(textureNumLevels(prefilter_cube) - 1u);
}

fn fresnel_schlick_roughness(cos_theta: f32, f0: vec3f, roughness: f32) -> vec3f {
    return f0 + (max(vec3f(1.0 - roughness), f0) - f0) * pow(clamp(1.0 - cos_theta, 0.0, 1.0), 5.0);
}

fn dir_to_equirect_uv(dir: vec3f) -> vec2f {
    let u = atan2(dir.z, dir.x) / (2.0 * PI) + 0.5;
    let v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
    return vec2f(u, v);
}

fn sample_skybox(camera: View, uv: vec2f) -> vec3f {
    let ndc = uv * 2.0 - 1.0;
    let world_far = camera.inv_view_projection * vec4f(ndc, 1.0, 1.0);
    let dir = normalize(world_far.xyz / world_far.w - camera.position.xyz);
    let blur = clamp(u.skybox_blur, 0.0, 1.0);
    if (blur <= 0.0 || u.prefilter == 0u) {
        return textureSampleLevel(environment_map, linear_repeat, dir_to_equirect_uv(dir), 0.0).rgb;
    }
    return textureSampleLevel(prefilter_cube, linear_clamp, dir, blur * prefilter_max_lod()).rgb;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    _ = LIGHT_TYPE;
    let camera = views[u.camera_index];
    let ibl_intensity = lights[in.light].color.a;
    let uv = in.clip.xy / camera.extent;
    let pixel = vec2i(in.clip.xy);
    let depth = scene_depth(pixel);
    // background (depth left at the far clear value): the skybox, if any
    if (depth >= 1.0) {
        if (u.skybox_intensity > 0.0 && u.environment != 0u) {
            return vec4f(sample_skybox(camera, uv) * u.skybox_intensity, 0.0);
        }
        discard;
    }
    let position = world_position(camera, uv, depth);
    let normal = textureLoad(normal_texture, pixel, 0).xyz * 2.0 - 1.0;
    let albedo = textureLoad(albedo_texture, pixel, 0).rgb;
    let mr = textureLoad(metallic_roughness_texture, pixel, 0).rg;
    let metallic = mr.r;
    let roughness = mr.g;
    let emissive = textureLoad(emissive_texture, pixel, 0).rgb;
    let v = normalize(camera.position.xyz - position);
    let r = reflect(-v, normal);
    let n_dot_v = max(dot(normal, v), 0.0);
    let f0 = mix(vec3f(0.04), albedo, metallic);
    let f = fresnel_schlick_roughness(n_dot_v, f0, roughness);
    var ambient = vec3f(0.0);
    if (ibl_intensity > 0.0 && u.prefilter != 0u) {
        let irradiance = textureSampleLevel(irradiance_cube, linear_clamp, normal, 0.0).rgb;
        let diffuse = irradiance * albedo;
        let kd = (vec3f(1.0) - f) * (1.0 - metallic);
        let prefiltered = textureSampleLevel(prefilter_cube, linear_clamp, r, roughness * prefilter_max_lod()).rgb;
        let brdf = textureSampleLevel(brdf_lut, linear_clamp, vec2f(n_dot_v, roughness), 0.0).rg;
        let specular = prefiltered * (f * brdf.x + brdf.y);
        ambient = (kd * diffuse + specular) * ibl_intensity;
    }
    return vec4f(ambient + emissive, 0.0);
}
