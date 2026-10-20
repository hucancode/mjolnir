// One thread per skinned vertex: deforms vertex v of its owner's mesh by the owner's bone
// palette into skinned[v], which the vertex shaders drawing the node read instead of the
// mesh's. A free vertex, one past the owner's mesh, or an invisible owner is skipped.
#include "common.slang"

SCENE_BUFFER(Node, nodes, 1, 0)
SCENE_BUFFER(MeshData, meshes, 2, 1)
SCENE_BUFFER(float4x4, bones, 4, 2)
SCENE_BUFFER(SkinningData, skinning, 5, 3)
// Vertex as 16 floats: position 0..3, normal 3..6, color 6..10, uv 10..12, tangent 12..16
SCENE_BUFFER(float, vertices, 17, 4)
// slot + 1 per skinned vertex, 0 for none
SCENE_BUFFER(uint, owners, 15, 5)
SCENE_BUFFER_RW(SkinnedVertex, skinned, 16, 6)

struct SkinPush { uint vertex_count; }
PUSH_BLOCK(SkinPush, push)

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 gid : SV_DispatchThreadID)
{
    uint v = gid.x;
    if (v >= push.vertex_count) { return; }
    uint owner = owners[v];
    if (owner == 0) { return; }
    Node node = nodes[owner - 1];
    uint required = NODE_FLAG_VISIBLE | NODE_FLAG_SKINNED;
    if ((node.flags & required) != required) { return; }
    MeshData mesh = meshes[node.mesh_id];
    uint local_index = v - node.skin_vertex_base;
    if (local_index >= mesh.vertex_count) { return; }

    uint base = uint(mesh.vertex_offset + int(local_index)) * 16;
    float3 position = float3(vertices[base], vertices[base + 1], vertices[base + 2]);
    float3 normal = float3(vertices[base + 3], vertices[base + 4], vertices[base + 5]);
    float4 tangent = float4(vertices[base + 12], vertices[base + 13], vertices[base + 14], vertices[base + 15]);

    SkinningData skin = skinning[mesh.skinning_offset + local_index];
    uint4 joints = skin.joints + uint4(node.attachment_data_index);
    float4x4 skin_matrix =
        skin.weights.x * bones[joints.x] +
        skin.weights.y * bones[joints.y] +
        skin.weights.z * bones[joints.z] +
        skin.weights.w * bones[joints.w];
    float3x3 skin3 = mat3_of(skin_matrix);
    SkinnedVertex result;
    result.position = float4(mul(skin_matrix, float4(position, 1.0)).xyz, 1.0);
    result.normal = float4(mul(skin3, normal), 0.0);
    result.tangent = float4(mul(skin3, tangent.xyz), tangent.w);
    skinned[v] = result;
}
