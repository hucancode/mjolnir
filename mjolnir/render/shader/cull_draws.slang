// wgpu only: writes the indirect draw of batch x in draw list y of the slot's buffer (layout in
// cull.slang), no instances: the cull counts those after. Wireframe and random-color draws
// are non-indexed (pulled from the index buffer): vertex count, instance count, first
// vertex, first instance. With first_instance a draw starts at its batch's instances, so
// one instance stream binding serves every batch.
#include "common.slang"

#if BACKEND_WGPU
SCENE_BUFFER(MeshData, meshes, 0, 2)
SCENE_BUFFER(Material, materials, 0, 3)
SCENE_BUFFER(Batch, batches, 0, 4)

struct BatchPush {
    uint node_count;
    uint first_view;
    uint instance_stride;
    uint draws_base;
    uint instances_base;
    uint max_batches;
    uint batch_count;
    // 1: a draw's first instance is where its batch's instances start (indirect first instance)
    uint first_instance;
}
PUSH_BLOCK(BatchPush, params)

[vk::binding(0, 3)] RWStructuredBuffer<Atomic<uint>> list;

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 gid : SV_DispatchThreadID, uint3 wid : SV_GroupID)
{
    uint id = gid.x;
    if (id >= params.batch_count) { return; }
    uint word = params.draws_base + (wid.y * params.max_batches + id) * 5;
    Batch batch = batches[id];
    uint draw[5] = { 0, 0, 0, 0, 0 };
    if (batch.capacity != 0) {
        MeshData mesh = meshes[batch.mesh_id];
        uint material_type = materials[batch.material_id].material_type;
        uint first = params.first_instance != 0 ? params.instances_base + wid.y * params.instance_stride + batch.first_instance : 0;
        if (material_type == MATERIAL_WIREFRAME || material_type == MATERIAL_RANDOM_COLOR) {
            draw[0] = material_type == MATERIAL_WIREFRAME ? mesh.index_count * 2 : mesh.index_count;
            draw[3] = first;
        } else {
            draw[0] = mesh.index_count;
            draw[2] = mesh.first_index;
            draw[3] = asuint(mesh.vertex_offset);
            draw[4] = first;
        }
    }
    for (uint k = 0; k < 5; k++) {
        list[word + k].store(draw[k]);
    }
}
#else
// the Vulkan cull writes its draws itself
[shader("compute")]
[numthreads(1, 1, 1)]
void main() {}
#endif
