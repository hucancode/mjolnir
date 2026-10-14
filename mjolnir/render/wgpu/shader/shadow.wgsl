// Shadow depth: the opaque candidates through one shadow view (scene group SHADOW), skinned
// like mesh.wgsl. One pass per view, into its atlas layer.

@group(0) @binding(0) var<storage, read> views: array<View>;
@group(0) @binding(1) var<storage, read> nodes: array<Node>;
@group(0) @binding(2) var<storage, read> meshes: array<Mesh>;
@group(0) @binding(3) var<storage, read> bones: array<mat4x4f>;
@group(0) @binding(4) var<storage, read> skinning: array<Skinning>;

struct ShadowUniforms {
    view_index: u32,
}
@group(2) @binding(0) var<uniform> u: ShadowUniforms;

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32, @location(0) position: vec3f, @location(5) node_index: u32) -> @builtin(position) vec4f {
    let node = nodes[node_index];
    var model_position = vec4f(position, 1.0);
    if ((node.flags & NODE_FLAG_SKINNED) != 0u) {
        let mesh = meshes[node.mesh_id];
        let skin = skinning[mesh.skinning_offset + u32(i32(vertex_index) - mesh.vertex_offset)];
        let joints = skin.joints + vec4u(node.attachment_data_index);
        let skin_matrix =
            skin.weights.x * bones[joints.x] +
            skin.weights.y * bones[joints.y] +
            skin.weights.z * bones[joints.z] +
            skin.weights.w * bones[joints.w];
        model_position = skin_matrix * model_position;
    }
    return clip_output(views[u.view_index].view_projection * node.world_matrix * model_position);
}
