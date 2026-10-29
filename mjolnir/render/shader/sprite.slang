// Sprite: a camera-facing billboard at the node's position, scaled by its world scale (mirrored
// when the scale is), showing cell frame_index (row-major) of the albedo sprite sheet. Pixels
// under half alpha are cut out; the rest write depth, so depth orders overlapping sprites.
#include "common.slang"

SCENE_BUFFER(Node, nodes, 1, 1)
SCENE_BUFFER(Material, materials, 3, 3)

struct MeshPush { uint camera_index; }
PUSH_BLOCK(MeshPush, mesh_push)

#if BACKEND_WGPU
[vk::binding(0, 1)] Texture2D albedo_texture;
#else
[vk::binding(0, TEXTURES_SET)] Texture2D textures[];
#endif

struct VertexIn {
    [vk::location(0)] float3 position : TEXCOORD0;
    [vk::location(2)] float4 color : TEXCOORD2;
    [vk::location(3)] float2 uv : TEXCOORD3;
#if BACKEND_WGPU
    [vk::location(5)] uint node_index : TEXCOORD5;
#else
    uint node_index : SV_VulkanInstanceID;
#endif
}

struct VertexOut {
    float4 clip : SV_Position;
    [vk::location(0)] float3 position : POSITION;
    [vk::location(1)] float4 color : COLOR0;
    [vk::location(2)] float2 uv : TEXCOORD0;
#if !BACKEND_WGPU
    [vk::location(3)] nointerpolation uint texture_index : TEXTURE_INDEX;
#endif
}

// Column i of a matrix.
float3 column3(float4x4 m, uint i)
{
    return float3(m[0][i], m[1][i], m[2][i]);
}

[shader("vertex")]
VertexOut vs_main(VertexIn v)
{
    View camera = views[mesh_push.camera_index];
    Node node = nodes[v.node_index];
    float4x4 world = node.world_matrix;
    Material sprite = materials[node.material_id];
    float3 camera_right = camera.view[0].xyz;
    float3 camera_up = camera.view[1].xyz;
    float3 world_pos = column3(world, 3);
    // the scale is the length of each basis column; a mirrored basis mirrors the sprite
    float mirror = sign(determinant(mat3_of(world)));
    float scale_x = length(column3(world, 0)) * mirror;
    float scale_y = length(column3(world, 1));
    float3 vertex_pos = world_pos + camera_right * (v.position.x * scale_x) + camera_up * (v.position.y * scale_y);
    float2 frame_size = float2(1.0 / float(sprite.frame_columns), 1.0 / float(sprite.frame_rows));
    uint cell = sprite.frame_index % (sprite.frame_columns * sprite.frame_rows);
    uint column = cell % sprite.frame_columns;
    uint row = cell / sprite.frame_columns;
    VertexOut o;
    o.uv = v.uv * frame_size + float2(float(column), float(row)) * frame_size;
    o.color = v.color * sprite.base_color_factor;
    o.position = vertex_pos;
#if !BACKEND_WGPU
    o.texture_index = sprite.albedo_index;
#endif
    o.clip = clip_output(mul(mul(camera.projection, camera.view), float4(vertex_pos, 1.0)));
    return o;
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
#if BACKEND_WGPU
    float4 color = albedo_texture.Sample(nearest_clamp, v.uv) * v.color;
#else
    float4 color = textures[NonUniformResourceIndex(v.texture_index)].Sample(samplers[SAMPLER_NEAREST_CLAMP], v.uv) * v.color;
#endif
    // reconsider this if we want to support semi-transparent sprite
    if (color.a < 0.5) {
        discard;
    }
    return color;
}
