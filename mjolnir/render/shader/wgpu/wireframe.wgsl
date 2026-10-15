// Wireframe: a line list of every triangle edge in the vertex color. Vertex v of the draw is
// endpoint v % 2 of edge (v % 6) / 2 of triangle v / 6.

fn pulled_index(v: u32) -> u32 {
    let corner = ((v % 6u) / 2u + v % 2u) % 3u;
    return (v / 6u) * 3u + corner;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4f {
    return vec4f(in.color.rgb, 1.0);
}
