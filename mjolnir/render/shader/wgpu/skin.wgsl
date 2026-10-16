// One thread per skinned vertex (scene group SKIN): deforms vertex v of its owner's mesh by
// the owner's bone palette into skinned[v], which the vertex shaders drawing the node read
// instead of the mesh's. A free vertex, one past the owner's mesh, or an invisible owner is
// skipped.

@group(0) @binding(0) var<storage, read> nodes: array<Node>;
@group(0) @binding(1) var<storage, read> meshes: array<Mesh>;
@group(0) @binding(2) var<storage, read> bones: array<mat4x4f>;
@group(0) @binding(3) var<storage, read> skinning: array<Skinning>;
// Vertex as 16 floats: position 0..3, normal 3..6, color 6..10, uv 10..12, tangent 12..16
@group(0) @binding(4) var<storage, read> vertices: array<f32>;
// slot + 1 per skinned vertex, 0 for none
@group(0) @binding(5) var<storage, read> owners: array<u32>;
@group(0) @binding(6) var<storage, read_write> skinned: array<SkinnedVertex>;

struct SkinUniforms {
    vertex_count: u32,
}
@group(2) @binding(0) var<uniform> u: SkinUniforms;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3u) {
    let v = gid.x;
    if (v >= u.vertex_count) { return; }
    let owner = owners[v];
    if (owner == 0u) { return; }
    let node = nodes[owner - 1u];
    let required = NODE_FLAG_VISIBLE | NODE_FLAG_SKINNED;
    if ((node.flags & required) != required) { return; }
    let mesh = meshes[node.mesh_id];
    let local_index = v - node.skin_vertex_base;
    if (local_index >= mesh.vertex_count) { return; }

    let base = u32(mesh.vertex_offset + i32(local_index)) * 16u;
    let position = vec3f(vertices[base], vertices[base + 1u], vertices[base + 2u]);
    let normal = vec3f(vertices[base + 3u], vertices[base + 4u], vertices[base + 5u]);
    let tangent = vec4f(vertices[base + 12u], vertices[base + 13u], vertices[base + 14u], vertices[base + 15u]);

    let skin = skinning[mesh.skinning_offset + local_index];
    let joints = skin.joints + vec4u(node.attachment_data_index);
    let skin_matrix =
        skin.weights.x * bones[joints.x] +
        skin.weights.y * bones[joints.y] +
        skin.weights.z * bones[joints.z] +
        skin.weights.w * bones[joints.w];
    let skin3 = mat3_of(skin_matrix);
    skinned[v] = SkinnedVertex(
        vec4f((skin_matrix * vec4f(position, 1.0)).xyz, 1.0),
        vec4f(skin3 * normal, 0.0),
        vec4f(skin3 * tangent.xyz, tangent.w),
    );
}
