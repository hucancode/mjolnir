// Shadow depth: the opaque batches through one shadow view, skinned like mesh_vertex.slang.
// Vulkan draws one node into one view's atlas layer: the cull tags each draw, first_instance =
// node | view << 16. On wgpu one pass renders every view, each into its atlas tile's viewport,
// the view in the push.
#include "common.slang"

SCENE_BUFFER(Node, nodes, 1, 1)
SCENE_BUFFER(MeshData, meshes, 2, 2)
// what the skinning pass wrote
SCENE_BUFFER(SkinnedVertex, skinned, 16, 3)

#if BACKEND_WGPU
struct ShadowPush { uint view_index; }
PUSH_BLOCK(ShadowPush, shadow_push)
#endif

struct ShadowIn {
    [vk::location(0)] float3 position : TEXCOORD0;
#if BACKEND_WGPU
    [vk::location(5)] uint node_index : TEXCOORD5;
#else
    uint instance : SV_VulkanInstanceID;
#endif
#if BACKEND_WGPU
    uint vertex_index : SV_VertexID;
#else
    uint vertex_index : SV_VulkanVertexID;
#endif
}

struct ShadowOut {
    float4 clip : SV_Position;
#if !BACKEND_WGPU
    uint layer : SV_RenderTargetArrayIndex;
#endif
}

[shader("vertex")]
ShadowOut vs_main(ShadowIn v)
{
#if BACKEND_WGPU
    uint node_index = v.node_index;
    View view = views[shadow_push.view_index];
#else
    uint node_index = v.instance & 0xFFFFu;
    View view = views[v.instance >> 16];
#endif
    Node node = nodes[node_index];
    float4 model_position = float4(v.position, 1.0);
    // only set on a skinned mesh
    if ((node.flags & NODE_FLAG_SKINNED) != 0) {
        MeshData mesh = meshes[node.mesh_id];
        model_position = float4(skinned[node.skin_vertex_base + uint(int(v.vertex_index) - mesh.vertex_offset)].position.xyz, 1.0);
    }
    ShadowOut o;
    o.clip = clip_output(mul(view.view_projection, mul(node.world_matrix, model_position)));
#if !BACKEND_WGPU
    o.layer = view.layer;
#endif
    return o;
}
