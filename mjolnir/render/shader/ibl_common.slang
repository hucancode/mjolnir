// Bindings and helpers of the IBL precompute (pass_ibl.odin): each dispatch writes one cube
// level as six storage layers, one thread per texel per face, from the mipped equirect map.
#pragma once
#include "common.slang"

struct PrecomputePush {
    // bindless indices on Vulkan; wgpu binds source and destination as a group
    uint source_index;
    uint destination_index;
    // edge length of the destination level
    uint face_size;
    // the irradiance sample step, or the prefilter roughness
    float value;
    // GGX samples per texel (prefilter)
    uint sample_count;
}
PUSH_BLOCK(PrecomputePush, precompute_push)

#if BACKEND_WGPU
[vk::binding(1, 3)] [format("rgba16f")] WTexture2DArray<float4> destination;
[vk::binding(0, 3)] Texture2D source;
#else
// aliases the depth pyramid's storage images
[vk::binding(2, TEXTURES_SET)] [format("rgba16f")] RWTexture2DArray<float4> storage_cubes[];
[vk::binding(0, TEXTURES_SET)] Texture2D textures[];
#endif

// The source in direction `dir` at mip `lod`.
float3 sample_source(float3 dir, float lod)
{
    float2 uv = dir_to_equirect_uv(dir);
#if BACKEND_WGPU
    return source.SampleLevel(linear_repeat, uv, lod).rgb;
#else
    return textures[NonUniformResourceIndex(precompute_push.source_index)].SampleLevel(samplers[SAMPLER_LINEAR_REPEAT], uv, lod).rgb;
#endif
}

// The mip whose texels cover about `solid_angle` steradians around `dir`. A sample standing
// for more than its own texel reads a filtered one, so a tiny bright sun is spread over the
// samples that represent it and does not speckle the result.
float source_lod(float3 dir, float solid_angle)
{
    uint w, h, levels;
#if BACKEND_WGPU
    source.GetDimensions(0, w, h, levels);
#else
    textures[NonUniformResourceIndex(precompute_push.source_index)].GetDimensions(0, w, h, levels);
#endif
    float sin_theta = max(sqrt(1.0 - dir.y * dir.y), 0.01);
    float texel = (2.0 * PI / float(w)) * (PI / float(h)) * sin_theta;
    return clamp(0.5 * log2(solid_angle / texel), 0.0, float(levels - 1));
}

void store_destination(uint3 gid, float4 value)
{
#if BACKEND_WGPU
    destination.Store(int3(gid), value);
#else
    storage_cubes[precompute_push.destination_index][gid] = value;
#endif
}

// Direction through texel uv in [-1, 1] of cube face `face` (+X, -X, +Y, -Y, +Z, -Z).
float3 face_dir(uint face, float2 uv)
{
    float3 d;
    switch (face) {
    case 0: d = float3(1.0, -uv.y, -uv.x); break;
    case 1: d = float3(-1.0, -uv.y, uv.x); break;
    case 2: d = float3(uv.x, 1.0, uv.y); break;
    case 3: d = float3(uv.x, -1.0, -uv.y); break;
    case 4: d = float3(uv.x, -uv.y, 1.0); break;
    default: d = float3(-uv.x, -uv.y, -1.0); break;
    }
    return normalize(d);
}

// The texel's direction, false past the level's edge.
bool texel_dir(uint3 gid, out float3 dir)
{
    dir = float3(0.0);
    if (gid.x >= precompute_push.face_size || gid.y >= precompute_push.face_size || gid.z >= 6) {
        return false;
    }
    float2 uv = (float2(gid.xy) + 0.5) / float(precompute_push.face_size) * 2.0 - 1.0;
    dir = face_dir(gid.z, uv);
    return true;
}
