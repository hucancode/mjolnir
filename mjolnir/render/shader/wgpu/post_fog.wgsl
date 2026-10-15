// FogEffect: blends toward color between view depth start and end.

struct Effect {
    color: vec3f,
    start: f32,
    end: f32,
}

// Distance along the view axis from a [0, 1] perspective depth value.
fn linearize_depth(depth: f32) -> f32 {
    return u.camera_near * u.camera_far / (u.camera_far - depth * (u.camera_far - u.camera_near));
}

fn fog_factor(distance: f32) -> f32 {
    if (distance >= u.effect.end) {
        return 1.0;
    }
    if (distance <= u.effect.start) {
        return 0.0;
    }
    return clamp((distance - u.effect.start) / (u.effect.end - u.effect.start), 0.0, 1.0);
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let color = textureSample(input_texture, linear_clamp, in.uv);
    let factor = fog_factor(linearize_depth(depth_at(in.uv)));
    return vec4f(mix(color.rgb, u.effect.color, factor), 1.0);
}
