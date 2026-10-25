// Particles drawn in the forward pass. Vulkan: one point per alive particle, sized by
// SV_PointSize. wgpu (points are one pixel): a camera-facing quad (six vertices) per alive
// particle, instanced, sized in pixels as the Vulkan point size; textures come from the
// PARTICLES group: slot j holds the texture handle push.textures[j].
#include "common.slang"

struct Particle {
    float3 position;
    float size_start;
    float3 velocity;
    float size_end;
    float4 color_start;
    float4 color_end;
    float life;
    float max_life;
    float weight;
    uint texture_index;
    float drag;
    float _pad0;
    float _pad1;
    float _pad2;
}

SCENE_BUFFER(Particle, particles, 8, 1)
// the indirect draw header (4 words), then the alive particles' indices
SCENE_BUFFER(uint, alive, 9, 2)

#if BACKEND_WGPU
[vk::binding(0, 1)] Texture2D texture0;
[vk::binding(1, 1)] Texture2D texture1;
[vk::binding(2, 1)] Texture2D texture2;
[vk::binding(3, 1)] Texture2D texture3;
[vk::binding(4, 1)] Texture2D texture4;
[vk::binding(5, 1)] Texture2D texture5;
[vk::binding(6, 1)] Texture2D texture6;
[vk::binding(7, 1)] Texture2D texture7;
#else
[vk::binding(0, TEXTURES_SET)] Texture2D textures[];
#endif

struct ParticleDrawPush {
    uint camera_index;
#if BACKEND_WGPU
    uint _pad0;
    uint _pad1;
    uint _pad2;
    // the texture handle each slot of the group holds
    uint4 textures[2];
#endif
}
PUSH_BLOCK(ParticleDrawPush, push)

struct VertexOut {
    float4 clip : SV_Position;
    [vk::location(0)] float4 color : COLOR0;
#if BACKEND_WGPU
    // gl_PointCoord: 0 at the quad's top left
    [vk::location(1)] float2 uv : TEXCOORD0;
    [vk::location(2)] nointerpolation uint texture_index : TEXTURE_INDEX;
#else
    [vk::location(1)] nointerpolation uint texture_index : TEXTURE_INDEX;
#endif
}

static const uint ALIVE_HEADER = 4;

#if !BACKEND_WGPU
struct PointOut {
    VertexOut v;
    float point_size : SV_PointSize;
}
#endif

#if BACKEND_WGPU
#define VS_OUT VertexOut
#else
#define VS_OUT PointOut
#endif

[shader("vertex")]
VS_OUT vs_main(
#if BACKEND_WGPU
    uint vertex_index : SV_VertexID, uint instance : SV_InstanceID
#else
    uint vertex_index : SV_VulkanVertexID
#endif
)
{
    View camera = views[push.camera_index];
#if BACKEND_WGPU
    static const float2 corners[6] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(1.0, 1.0), float2(-1.0, -1.0), float2(1.0, 1.0), float2(-1.0, 1.0) };
    float2 corner = corners[vertex_index];
    Particle p = particles[alive[ALIVE_HEADER + instance]];
#else
    // one vertex per live particle
    Particle p = particles[alive[ALIVE_HEADER + vertex_index]];
#endif
    float ratio = p.life / p.max_life;
    float size = lerp(p.size_end, p.size_start, ratio);
    float dist = clamp(length(camera.position.xyz - p.position), 1.0, 20.0);
    // the Vulkan point size: the quad's side in pixels
    float pixels = clamp(size / dist, 10.0, 100.0);
    float4 clip = mul(mul(camera.projection, camera.view), float4(p.position, 1.0));
    VertexOut o;
    o.color = lerp(p.color_end, p.color_start, ratio);
    o.texture_index = p.texture_index;
#if BACKEND_WGPU
    // Vulkan clip space: +y is down the screen, as uv
    clip = float4(clip.xy + corner * pixels / camera.extent * clip.w, clip.zw);
    o.uv = corner * 0.5 + 0.5;
#else
#endif
    o.clip = clip_output(clip);
#if BACKEND_WGPU
    return o;
#else
    PointOut r;
    r.v = o;
    r.point_size = pixels;
    return r;
#endif
}

#if BACKEND_WGPU
// Alpha of the particle's texture at uv: 1 without one, or past the group's slots.
float texture_alpha(uint handle, float2 uv)
{
    if (handle == NO_TEXTURE) return 1.0;
    uint slot = 8;
    for (uint j = 0; j < 8; j++) {
        if (push.textures[j / 4][j % 4] == handle) {
            slot = j;
            break;
        }
    }
    switch (slot) {
    case 0: return texture0.SampleLevel(linear_repeat, uv, 0.0).a;
    case 1: return texture1.SampleLevel(linear_repeat, uv, 0.0).a;
    case 2: return texture2.SampleLevel(linear_repeat, uv, 0.0).a;
    case 3: return texture3.SampleLevel(linear_repeat, uv, 0.0).a;
    case 4: return texture4.SampleLevel(linear_repeat, uv, 0.0).a;
    case 5: return texture5.SampleLevel(linear_repeat, uv, 0.0).a;
    case 6: return texture6.SampleLevel(linear_repeat, uv, 0.0).a;
    case 7: return texture7.SampleLevel(linear_repeat, uv, 0.0).a;
    default: return 1.0;
    }
}
#else
float texture_alpha(uint handle, float2 uv)
{
    if (handle == NO_TEXTURE) return 1.0;
    return textures[NonUniformResourceIndex(handle)].Sample(samplers[SAMPLER_LINEAR_REPEAT], uv).a;
}
#endif

[shader("fragment")]
float4 fs_main(VertexOut v
#if !BACKEND_WGPU
    , float2 point_coord : SV_PointCoord
#endif
) : SV_Target0
{
#if BACKEND_WGPU
    float2 uv = v.uv;
#else
    float2 uv = point_coord;
#endif
    float4 color = float4(v.color.rgb, texture_alpha(v.texture_index, uv) * v.color.a);
    if (color.a < 0.01) {
        discard;
    }
    return color;
}
