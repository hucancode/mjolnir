// What the vertex and fragment shaders of mesh materials share: the scene buffers, the push,
// the vertex stream and the varyings. Included after common.slang.
#pragma once
#include "common.slang"

SCENE_BUFFER(Node, nodes, 1, 1)
SCENE_BUFFER(MeshData, meshes, 2, 2)
SCENE_BUFFER(Material, materials, 3, 3)
// what the skinning pass wrote
SCENE_BUFFER(SkinnedVertex, skinned, 16, 4)

struct MeshPush {
    uint camera_index;
    // the sun's light and node (pass_material.odin), light 0 for none
    uint sun_light;
    uint sun_node;
}
PUSH_BLOCK(MeshPush, mesh_push)

struct VertexIn {
    [vk::location(0)] float3 position : POSITION;
    [vk::location(1)] float3 normal : NORMAL;
    [vk::location(2)] float4 color : COLOR0;
    [vk::location(3)] float2 uv : TEXCOORD0;
    [vk::location(4)] float4 tangent : TANGENT;
    // the draw's node: the instance index on Vulkan, an instance-stepped attribute on wgpu
#if BACKEND_WGPU
    [vk::location(5)] uint node_index : NODE_INDEX;
#else
    uint node_index : SV_VulkanInstanceID;
#endif
#if BACKEND_WGPU
    uint vertex_index : SV_VertexID;
#else
    uint vertex_index : SV_VulkanVertexID;
#endif
}

struct VertexOut {
    float4 clip : SV_Position;
    [vk::location(0)] float3 position : POSITION;
    [vk::location(1)] float4 color : COLOR0;
    [vk::location(2)] float3 normal : NORMAL;
    [vk::location(3)] float2 uv : TEXCOORD0;
    [vk::location(4)] float4 tangent : TANGENT;
    [vk::location(5)] nointerpolation uint node_index : NODE_INDEX;
}

// The drawing camera's view.
View camera_view()
{
    return views[mesh_push.camera_index];
}
