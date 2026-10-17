// Shadow depth: the opaque batches through one shadow view (scene group SHADOW), skinned
// like mesh.wgsl. One pass renders every view, each into its atlas tile's viewport.

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> nodes: array<Node>;
@group(0) @binding(2) var<storage, read> meshes: array<MeshData>;
@group(0) @binding(3) var<storage, read> skinned: array<SkinnedVertex>;

struct ShadowPush {
    view_index: u32,
}
@group(2) @binding(0) var<uniform> u: ShadowPush;

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @location(0) position: vec3f, @location(5) node_index: u32) -> @builtin(position) vec4f {
    let node = nodes[node_index];
    var model_position = vec4f(position, 1.0);
    if ((node.flags & NODE_FLAG_SKINNED) != 0u) {
        let mesh = meshes[node.mesh_id];
        model_position = vec4f(skinned[node.skin_vertex_base + u32(i32(vertex_index) - mesh.vertex_offset)].position.xyz, 1.0);
    }
    return clip_output(views[u.view_index].view_projection * node.world_matrix * model_position);
}
