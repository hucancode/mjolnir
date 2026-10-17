// Writes the indirect draw of batch x in draw list y of the slot's buffer (layout in
// cull.wgsl), no instances: the cull counts those after. Wireframe and random-color draws
// are non-indexed (pulled from the index buffer): vertex count, instance count, first
// vertex, first instance. With first_instance a draw starts at its batch's instances, so
// one instance stream binding serves every batch.

@group(0) @binding(2) var<storage, read> meshes: array<MeshData>;
@group(0) @binding(3) var<storage, read> materials: array<Material>;
@group(0) @binding(4) var<storage, read> batches: array<Batch>;

struct BatchPush {
    node_count: u32,
    first_view: u32,
    instance_stride: u32,
    draws_base: u32,
    instances_base: u32,
    max_batches: u32,
    batch_count: u32,
    // 1: a draw's first instance is where its batch's instances start (indirect first instance)
    first_instance: u32,
}
@group(2) @binding(0) var<uniform> u: BatchPush;

@group(3) @binding(0) var<storage, read_write> list: array<atomic<u32>>;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) gid: vec3u, @builtin(workgroup_id) wid: vec3u) {
    let id = gid.x;
    if (id >= u.batch_count) { return; }
    let word = u.draws_base + (wid.y * u.max_batches + id) * 5u;
    let batch = batches[id];
    var draw = array<u32, 5>(0u, 0u, 0u, 0u, 0u);
    if (batch.capacity != 0u) {
        let mesh = meshes[batch.mesh_id];
        let material_type = materials[batch.material_id].material_type;
        let first = select(0u, u.instances_base + wid.y * u.instance_stride + batch.first_instance, u.first_instance != 0u);
        if (material_type == MATERIAL_WIREFRAME || material_type == MATERIAL_RANDOM_COLOR) {
            draw[0] = select(mesh.index_count, mesh.index_count * 2u, material_type == MATERIAL_WIREFRAME);
            draw[3] = first;
        } else {
            draw[0] = mesh.index_count;
            draw[2] = mesh.first_index;
            draw[3] = bitcast<u32>(mesh.vertex_offset);
            draw[4] = first;
        }
    }
    for (var k = 0u; k < 5u; k++) {
        atomicStore(&list[word + k], draw[k]);
    }
}
