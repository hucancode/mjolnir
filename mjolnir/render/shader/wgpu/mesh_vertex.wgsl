// The vertex shader of mesh materials (mesh.wgsl); a skinned node's vertices are the skinning
// pass's.

@vertex
fn vs_main(in: VertexIn) -> VertexOut {
    let camera = views[u.camera_index];
    let node = nodes[in.node_index];
    let world = node.world_matrix;
    var model_position = vec4f(in.position, 1.0);
    var model_normal = in.normal;
    var model_tangent = in.tangent;
    if ((node.flags & NODE_FLAG_SKINNED) != 0u) {
        let mesh = meshes[node.mesh_id];
        let skin = skinned[node.skin_vertex_base + u32(i32(in.vertex_index) - mesh.vertex_offset)];
        model_position = vec4f(skin.position.xyz, 1.0);
        model_normal = skin.normal.xyz;
        model_tangent = skin.tangent;
    }
    let world_position = world * model_position;
    var out: VertexOut;
    out.normal = normalize(mat3_of(world) * model_normal);
    out.tangent = vec4f(normalize(mat3_of(world) * model_tangent.xyz), model_tangent.w);
    out.uv = in.uv;
    out.color = in.color;
    out.position = world_position.xyz;
    out.node_index = in.node_index;
    out.clip = clip_output(camera.projection * camera.view * world_position);
    return out;
}
