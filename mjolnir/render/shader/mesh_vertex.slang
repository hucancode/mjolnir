// The vertex shader of mesh materials (mesh.slang); a skinned node's vertices are the skinning
// pass's.
#pragma once
#include "mesh.slang"

[shader("vertex")]
VertexOut vs_main(VertexIn v)
{
    View camera = camera_view();
    Node node = nodes[v.node_index];
    float4x4 world = node.world_matrix;
    float4 model_position = float4(v.position, 1.0);
    float3 model_normal = v.normal;
    float4 model_tangent = v.tangent;
    // only set on a skinned mesh
    if ((node.flags & NODE_FLAG_SKINNED) != 0) {
        MeshData mesh = meshes[node.mesh_id];
        SkinnedVertex skin = skinned[node.skin_vertex_base + uint(int(v.vertex_index) - mesh.vertex_offset)];
        model_position = float4(skin.position.xyz, 1.0);
        model_normal = skin.normal.xyz;
        model_tangent = skin.tangent;
    }
    float4 world_position = mul(world, model_position);
    VertexOut o;
    o.normal = normalize(mul(mat3_of(world), model_normal));
    o.tangent = float4(normalize(mul(mat3_of(world), model_tangent.xyz)), model_tangent.w);
    o.uv = v.uv;
    o.color = v.color;
    o.position = world_position.xyz;
    o.node_index = v.node_index;
    o.clip = clip_output(mul(mul(camera.projection, camera.view), world_position));
    return o;
}
