// The 2D overlay: pixel-space vertices through an orthographic projection, one texture and sampler per
// batch (a push on Vulkan, the pass's single texture group on wgpu). Glyph atlases are white
// with coverage in alpha, so one multiply serves glyphs, solid quads (white texture) and images.
// Vertex colours are sRGB, as authored; they are made linear here, as the sRGB target expects.
#include "common.slang"

struct OverlayPush {
    float4x4 projection;
    uint texture_id; // the bindless index on Vulkan; wgpu binds the texture instead
    uint sampler_id;
}
PUSH_BLOCK(OverlayPush, overlay)

#if BACKEND_WGPU
[vk::binding(0, 1)] Texture2D batch_texture;
#else
[vk::binding(0, TEXTURES_SET)] Texture2D textures[];
#endif

struct VertexOut {
    float4 clip : SV_Position;
    [vk::location(0)] float4 color : COLOR0;
    [vk::location(1)] float2 uv : TEXCOORD0;
}

[shader("vertex")]
VertexOut vs_main([vk::location(0)] float2 position : POSITION, [vk::location(1)] float2 uv : TEXCOORD0, [vk::location(2)] float4 color : COLOR0)
{
    VertexOut o;
    o.clip = clip_output(mul(overlay.projection, float4(position, 0.0, 1.0)));
    o.color = float4(srgb_to_linear(color.rgb), color.a);
    o.uv = uv;
    return o;
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
#if BACKEND_WGPU
    // a sampler cannot be picked into a variable here: branch on the batch's (uniform) choice
    if (overlay.sampler_id == SAMPLER_LINEAR_CLAMP)
        return v.color * batch_texture.Sample(linear_clamp, v.uv);
    return v.color * batch_texture.Sample(nearest_clamp, v.uv);
#else
    return v.color * textures[NonUniformResourceIndex(overlay.texture_id)].Sample(sampler_of(overlay.sampler_id), v.uv);
#endif
}
