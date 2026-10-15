// Random color: each triangle a color hashed from its index and the node, in the material's
// alpha. Vertex v of the draw is the mesh's index v.

fn pulled_index(v: u32) -> u32 {
    return v;
}

fn hash(v: u32) -> f32 {
    var x = ((v >> 16u) ^ v) * 0x45d9f3bu;
    x = ((x >> 16u) ^ x) * 0x45d9f3bu;
    x = (x >> 16u) ^ x;
    return f32(x) / 4294967295.0;
}

fn hsv_to_rgb(hsv: vec3f) -> vec3f {
    let k = hsv.x * 6.0 + vec3f(0.0, 4.0, 2.0);
    let rgb = clamp(abs(k - 6.0 * floor(k / 6.0) - 3.0) - 1.0, vec3f(0.0), vec3f(1.0));
    return hsv.z * mix(vec3f(1.0), rgb, hsv.y);
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    let material = materials[nodes[in.node_index].material_id];
    let seed = in.primitive ^ (in.node_index * 2654435761u);
    let h = hash(seed);
    let s = 0.7 + hash(seed + 1u) * 0.3;
    let v = 0.8 + hash(seed + 2u) * 0.2;
    return vec4f(hsv_to_rgb(vec3f(h, s, v)), material.base_color_factor.a);
}
