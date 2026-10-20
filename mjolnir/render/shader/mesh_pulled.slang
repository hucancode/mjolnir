// The wgpu vertex shader of materials drawn without an index buffer (wireframe, random color):
// each vertex pulls its index from the index buffer and its vertex from the vertex buffer,
// both bound as storage (scene group MESH), skinned like mesh_vertex.slang. The draw is
// non-indexed from first vertex 0; pulled_index maps vertex_index to the k-th index of the
// mesh (the material's file declares it before including this). Vulkan draws these materials
// indexed with mesh_vertex.slang and reads the triangle from SV_PrimitiveID; PulledIn is the
// fragment input on both.
#pragma once
#include "mesh.slang"

#if BACKEND_WGPU
// Vertex as 16 floats: position 0..3, normal 3..6, color 6..10, uv 10..12, tangent 12..16
SCENE_BUFFER(float, vertices, 0, 5)
SCENE_BUFFER(uint, indices, 0, 6)

struct PulledIn {
    float4 clip : SV_Position;
    [vk::location(0)] float3 position : TEXCOORD0;
    [vk::location(1)] float4 color : TEXCOORD1;
    // the triangle of the vertex (gl_PrimitiveID of an indexed draw)
    [vk::location(2)] nointerpolation uint primitive : TEXCOORD2;
    [vk::location(5)] nointerpolation uint node_index : TEXCOORD5;
}

[shader("vertex")]
PulledIn vs_main(uint vertex_index : SV_VertexID, [vk::location(5)] uint node_index : TEXCOORD5)
{
    View camera = camera_view();
    Node node = nodes[node_index];
    MeshData mesh = meshes[node.mesh_id];
    uint k = pulled_index(vertex_index);
    int vertex = int(indices[mesh.first_index + k]) + mesh.vertex_offset;
    uint base = uint(vertex) * 16;
    float4 model_position = float4(vertices[base], vertices[base + 1], vertices[base + 2], 1.0);
    float4 color = float4(vertices[base + 6], vertices[base + 7], vertices[base + 8], vertices[base + 9]);
    if ((node.flags & NODE_FLAG_SKINNED) != 0) {
        model_position = float4(skinned[node.skin_vertex_base + uint(vertex - mesh.vertex_offset)].position.xyz, 1.0);
    }
    float4 world_position = mul(node.world_matrix, model_position);
    PulledIn o;
    o.position = world_position.xyz;
    o.color = color;
    o.primitive = k / 3;
    o.node_index = node_index;
    o.clip = clip_output(mul(mul(camera.projection, camera.view), world_position));
    return o;
}
#else
#include "mesh_vertex.slang"
typedef VertexOut PulledIn;
#endif
