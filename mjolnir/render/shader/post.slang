// The interface of a post-process fragment shader (render.post_shader_create): the fullscreen
// vertex stage, the previous passes' images and the push block. Declare struct Effect, the
// fields of the shader's params as render.make_custom_effect packs them, before including this
// (std430: prefer float4 and scalars, a float3 takes 16 bytes unless a float follows it), in the
// order of the Odin struct. `time` is render's clock and post_resolution() the image size:
//
//     struct Effect { float3 tint; float strength; }
//     #include "post.slang"
//     [shader("fragment")]
//     float4 fs_main(PostIn v) : SV_Target0 { return post_input(v.uv) * float4(effect().tint, 1) * effect().strength; }
#pragma once
#include "common.slang"

struct PostPush {
    // camera clip planes, for effects that linearize depth
    float camera_near;
    float camera_far;
    // texture handles; Vulkan indexes with them, wgpu binds them as a group
    uint normal_texture_index;
    uint depth_texture_index;
    uint input_image_index;
    uint original_image_index;
    // this pass of the effect, 0 .. passes - 1
    uint pass_index;
    // render's clock in seconds
    float time;
    // offset 32: the effect's params
    Effect effect;
}
PUSH_BLOCK(PostPush, post_push)

struct PostIn {
    float4 clip : SV_Position;
    // 0 at the top left
    [vk::location(0)] float2 uv : TEXCOORD0;
}

#if BACKEND_WGPU
[vk::binding(0, 1)] Texture2D input_texture;
// the previous pass's input
[vk::binding(1, 1)] Texture2D original_texture;
[vk::binding(2, 1)] Texture2D normal_texture;
[vk::binding(3, 1)] DepthTexture2D depth_texture;
#else
[vk::binding(0, TEXTURES_SET)] Texture2D textures[];
#endif

Effect effect() { return post_push.effect; }

// A triangle covering the screen; uv follows framebuffer coordinates.
[shader("vertex")]
PostIn vs_main(uint i : VERTEX_ID)
{
    static const float2 positions[3] = { float2(-1.0, 3.0), float2(3.0, -1.0), float2(-1.0, -1.0) };
    static const float2 uvs[3] = { float2(0.0, 2.0), float2(2.0, 0.0), float2(0.0, 0.0) };
    PostIn o;
    o.clip = clip_output(float4(positions[i], 0.0, 1.0));
    o.uv = uvs[i];
    return o;
}

// The image size in pixels.
float2 post_resolution()
{
    uint w, h;
#if BACKEND_WGPU
    input_texture.GetDimensions(w, h);
#else
    textures[NonUniformResourceIndex(post_push.input_image_index)].GetDimensions(w, h);
#endif
    return float2(w, h);
}

// The previous pass's output at uv.
float4 post_input(float2 uv)
{
#if BACKEND_WGPU
    return input_texture.Sample(linear_clamp, uv);
#else
    return textures[NonUniformResourceIndex(post_push.input_image_index)].Sample(samplers[SAMPLER_LINEAR_CLAMP], uv);
#endif
}

// The previous pass's input at uv.
float4 post_original(float2 uv)
{
#if BACKEND_WGPU
    return original_texture.Sample(linear_clamp, uv);
#else
    return textures[NonUniformResourceIndex(post_push.original_image_index)].Sample(samplers[SAMPLER_LINEAR_CLAMP], uv);
#endif
}

// The G-buffer normal at uv, as the G-buffer stores it.
float3 post_normal(float2 uv)
{
#if BACKEND_WGPU
    return normal_texture.Sample(nearest_clamp, uv).xyz;
#else
    return textures[NonUniformResourceIndex(post_push.normal_texture_index)].Sample(samplers[SAMPLER_NEAREST_CLAMP], uv).xyz;
#endif
}

// The [0, 1] depth at uv (a depth texture does not filter, so this is the texel's).
float post_depth(float2 uv)
{
#if BACKEND_WGPU
    uint w, h;
    depth_texture.GetDimensions(w, h);
    int2 size = int2(w, h);
    return depth_texture.Load(int3(clamp(int2(uv * float2(size)), int2(0), size - 1), 0));
#else
    return textures[NonUniformResourceIndex(post_push.depth_texture_index)].Sample(samplers[SAMPLER_NEAREST_CLAMP], uv).r;
#endif
}

// Distance along the view axis of a depth from post_depth.
float linearize_depth(float depth)
{
    return post_push.camera_near * post_push.camera_far / (post_push.camera_far - depth * (post_push.camera_far - post_push.camera_near));
}

float gaussian_weight(float distance, float sigma)
{
    return exp(-0.5 * distance * distance / (sigma * sigma));
}

// post_input at lod 0: for loops and branches, where implicit derivatives are not allowed.
float4 post_input_level(float2 uv)
{
#if BACKEND_WGPU
    return input_texture.SampleLevel(linear_clamp, uv, 0.0);
#else
    return textures[NonUniformResourceIndex(post_push.input_image_index)].SampleLevel(samplers[SAMPLER_LINEAR_CLAMP], uv, 0.0);
#endif
}

// post_original at lod 0.
float4 post_original_level(float2 uv)
{
#if BACKEND_WGPU
    return original_texture.SampleLevel(linear_clamp, uv, 0.0);
#else
    return textures[NonUniformResourceIndex(post_push.original_image_index)].SampleLevel(samplers[SAMPLER_LINEAR_CLAMP], uv, 0.0);
#endif
}
