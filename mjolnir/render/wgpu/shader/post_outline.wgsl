// OutlineEffect: edges where depth or normal change sharply.

struct Effect {
    color: vec3f,
    thickness: f32,
}

// Distance along the view axis from a [0, 1] perspective depth value.
fn linearize_depth(depth: f32) -> f32 {
    return u.camera_near * u.camera_far / (u.camera_far - depth * (u.camera_far - u.camera_near));
}

fn sample_normal(uv: vec2f) -> vec3f {
    let size = vec2i(textureDimensions(normal_texture));
    let n = textureLoad(normal_texture, clamp(vec2i(uv * vec2f(size)), vec2i(0), size - 1), 0).rgb;
    return normalize(n * 2.0 - 1.0);
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let scene = textureSample(input_texture, linear_clamp, in.uv);
    let texel = u.effect.thickness / vec2f(textureDimensions(input_texture));
    let dc = depth_at(in.uv);
    // sky / background: no outline
    if (dc >= 1.0) {
        return vec4f(scene.rgb, 1.0);
    }
    let left = vec2f(-texel.x, 0.0);
    let right = vec2f(texel.x, 0.0);
    let up = vec2f(0.0, texel.y);
    let down = vec2f(0.0, -texel.y);
    let lc = linearize_depth(dc);
    let ll = linearize_depth(depth_at(in.uv + left));
    let lr = linearize_depth(depth_at(in.uv + right));
    let lu = linearize_depth(depth_at(in.uv + up));
    let ld = linearize_depth(depth_at(in.uv + down));
    // relative depth difference; the tolerance scales with distance so far objects stay
    // outlined
    let depth_diff = max(max(abs(lc - ll), abs(lc - lr)), max(abs(lc - lu), abs(lc - ld)));
    let depth_edge = smoothstep(0.02 * lc, 0.05 * lc + 0.01, depth_diff);
    let nc = sample_normal(in.uv);
    let normal_diff = (1.0 - dot(nc, sample_normal(in.uv + left))) + (1.0 - dot(nc, sample_normal(in.uv + right)))
        + (1.0 - dot(nc, sample_normal(in.uv + up))) + (1.0 - dot(nc, sample_normal(in.uv + down)));
    let normal_edge = smoothstep(0.4, 0.8, normal_diff);
    let edge = clamp(max(depth_edge, normal_edge), 0.0, 1.0);
    return vec4f(mix(scene.rgb, u.effect.color, edge), 1.0);
}
