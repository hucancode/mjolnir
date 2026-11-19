// Sprite: a camera-facing billboard at the node's position showing the node's frame of the
// material's sprite frames (none: the whole albedo texture), the frame's quad scaled by the
// node's world scale (mirrored when the scale is) and drawn depth_offset toward the camera; a
// turned sprite's quad lies in the node's XY plane instead, through its whole transform.
// Opaque pixels write depth, so depth orders overlapping sprites; semi-transparent pixels are
// blended in a second draw over them, depth-tested without writing, in no particular order.
#include "common.slang"

SCENE_BUFFER(Node, nodes, 1, 1)
SCENE_BUFFER(SpriteFrame, sprite_frames, 21, 2)
SCENE_BUFFER(Material, materials, 3, 3)
#include "sprite_frame.slang"

struct MeshPush { uint camera_index; uint sun_light; uint sun_node; uint sprite_blend; }
PUSH_BLOCK(MeshPush, mesh_push)

// SPRITE_INDEXED (sprite_indexed.slang defines it): the albedo texture holds palette indices (R8) and the
// emissive slot the palette (256 x 1); the choice is made when compiling, so a pixel never branches on it.
#if BACKEND_WGPU
[vk::binding(0, 1)] Texture2D albedo_texture;
#ifdef SPRITE_INDEXED
[vk::binding(3, 1)] Texture2D palette_texture;
#endif
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
#ifdef SPRITE_INDEXED
    [vk::location(4)] nointerpolation uint palette_index : PALETTE_INDEX;
#endif
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
    SpriteFrame frame = sprite_frame_of(sprite, node);
    // the quad's corners are at +-1, its uv 0 at the top-left
    float2 corner = frame.offset + v.position.xy * 0.5 * frame.size;
    float3 camera_back = camera.view[2].xyz;
    float3 vertex_pos = world_pos + camera_right * (corner.x * scale_x) + camera_up * (corner.y * scale_y);
    if ((node.flags & NODE_FLAG_TURNED) != 0) {
        vertex_pos = mul(world, float4(corner, 0.0, 1.0)).xyz;
    }
    vertex_pos += camera_back * node.depth_offset;
    float2 top = lerp(frame.uv[0], frame.uv[1], v.uv.x);
    float2 bottom = lerp(frame.uv[3], frame.uv[2], v.uv.x);
    VertexOut o;
    o.uv = lerp(top, bottom, v.uv.y);
    o.color = v.color * sprite.base_color_factor;
    o.position = vertex_pos;
#if !BACKEND_WGPU
    o.texture_index = sprite.albedo_index;
#ifdef SPRITE_INDEXED
    o.palette_index = sprite.emissive_index;
#endif
#endif
    o.clip = clip_output(mul(mul(camera.projection, camera.view), float4(vertex_pos, 1.0)));
    return o;
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
#ifdef SPRITE_INDEXED
#if BACKEND_WGPU
    int index = int(albedo_texture.Sample(nearest_clamp, v.uv).r * 255.0 + 0.5);
    float4 color = palette_texture.Load(int3(index, 0, 0)) * v.color;
#else
    int index = int(textures[NonUniformResourceIndex(v.texture_index)].Sample(samplers[SAMPLER_NEAREST_CLAMP], v.uv).r * 255.0 + 0.5);
    float4 color = textures[NonUniformResourceIndex(v.palette_index)].Load(int3(index, 0, 0)) * v.color;
#endif
#elif BACKEND_WGPU
    float4 color = albedo_texture.Sample(nearest_clamp, v.uv) * v.color;
#else
    float4 color = textures[NonUniformResourceIndex(v.texture_index)].Sample(samplers[SAMPLER_NEAREST_CLAMP], v.uv) * v.color;
#endif
    // the first draw keeps the opaque pixels (they write depth), the second blends the rest
    bool opaque = color.a >= 0.999;
    if (opaque == (mesh_push.sprite_blend != 0) || color.a <= 0.0) {
        discard;
    }
    return color;
}
