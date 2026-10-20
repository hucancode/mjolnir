// The 2D overlay: pixel-space vertices through an orthographic projection, one texture per
// batch (a push on Vulkan, the pass's single texture group on wgpu). Glyph atlases are white
// with coverage in alpha, so one multiply serves glyphs, solid quads (white texture) and images.
#include "common.slang"

struct OverlayPush {
    float4x4 projection;
#if !BACKEND_WGPU
    uint texture_id;
#endif
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
    o.color = color;
    o.uv = uv;
    return o;
}

[shader("fragment")]
float4 fs_main(VertexOut v) : SV_Target0
{
#if BACKEND_WGPU
    return v.color * batch_texture.Sample(nearest_clamp, v.uv);
#else
    return v.color * textures[NonUniformResourceIndex(overlay.texture_id)].Sample(samplers[SAMPLER_NEAREST_CLAMP], v.uv);
#endif
}
