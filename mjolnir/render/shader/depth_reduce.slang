// Vulkan: builds every mip of a max-depth pyramid in one dispatch. Mip 0 is half the
// depth image's size; each texel holds the farthest depth of the 2x2 texels
// below it. A group reduces a 32x32 tile of mip 0 down to mip 5 in shared
// memory; the last group to finish, found with a global counter, reduces the
// remaining mips from mip 5. Pyramid slot params.slot owns storage images
// [slot * MAX_MIPS, slot * MAX_MIPS + mip_count) and counter slot.
// wgpu: one level of a max-depth pyramid: each texel holds the farthest depth of the 2x2 source
// texels below it (source: the depth image for mip 0, read as unfilterable float, half its
// size, the mip above otherwise). Clamping repeats the last row and column of an odd-sized
// source.
#include "common.slang"

#if BACKEND_WGPU
[vk::binding(0, 3)] Texture2D source;
[vk::binding(1, 3)] [vk::image_format("r32f")] WTexture2D<float> destination;

float source_texel(int2 p)
{
    return source.Load(int3(p, 0)).r;
}

[shader("compute")]
[numthreads(8, 8, 1)]
void main(uint3 gid : SV_DispatchThreadID)
{
    uint width, height;
    destination.GetDimensions(width, height);
    if (gid.x >= width || gid.y >= height) { return; }
    uint source_width, source_height, source_levels;
    source.GetDimensions(0, source_width, source_height, source_levels);
    int2 last = int2(source_width, source_height) - 1;
    int2 p = int2(gid.xy) * 2;
    int2 lo = min(p, last);
    int2 hi = min(p + 1, last);
    float value = max(
        max(source_texel(lo), source_texel(int2(hi.x, lo.y))),
        max(source_texel(int2(lo.x, hi.y)), source_texel(hi)));
    destination.Store(int2(gid.xy), value);
}
#else
static const uint MAX_MIPS = 16;
// mip 0 texels per tile side
static const uint TILE = 32;
// mips 0..5 come from the tile
static const uint TILE_MIPS = 6;

struct DepthReducePush {
    // bindless depth image
    uint depth_index;
    uint mip_count;
    uint group_count;
    uint slot;
}
PUSH_BLOCK(DepthReducePush, params)

[vk::binding(0, 1)] Texture2D textures[];

[vk::binding(2, 1)] [vk::image_format("r32f")] globallycoherent RWTexture2D<float> storage_images[];
// groups done this dispatch, per pyramid slot; the last group resets it
[vk::binding(4, 1)] globallycoherent RWStructuredBuffer<uint> finished_groups;

groupshared float tile[TILE / 2][TILE / 2];
groupshared bool is_last_group;

RWTexture2D<float> mips(uint mip)
{
    return storage_images[params.slot * MAX_MIPS + mip];
}

int2 mip_size(uint mip)
{
    uint width, height;
    mips(mip).GetDimensions(width, height);
    return int2(width, height);
}

// Farthest depth of mip 0 texel p: the 2x2 depth texels below it. Clamping
// repeats the last row and column of an odd-sized image.
float mip0_value(int2 p, int2 size)
{
    Texture2D depth = textures[NonUniformResourceIndex(params.depth_index)];
    int2 lo = min(p * 2, size - 1);
    int2 hi = min(p * 2 + 1, size - 1);
    return max(max(depth.Load(int3(lo, 0)).r, depth.Load(int3(hi.x, lo.y, 0)).r),
               max(depth.Load(int3(lo.x, hi.y, 0)).r, depth.Load(int3(hi, 0)).r));
}

void store(uint mip, int2 p, float value)
{
    if (mip >= params.mip_count) return;
    if (any(p >= mip_size(mip))) return;
    mips(mip)[p] = value;
}

[shader("compute")]
[numthreads(256, 1, 1)]
void main(uint tid : SV_GroupIndex, uint3 wid : SV_GroupID)
{
    uint depth_width, depth_height, depth_levels;
    textures[NonUniformResourceIndex(params.depth_index)].GetDimensions(0, depth_width, depth_height, depth_levels);
    int2 size = int2(depth_width, depth_height);
    int2 tile_origin = int2(wid.xy) * int(TILE);

    // Mips 0 and 1: each thread owns a 2x2 block of mip 0, one mip 1 texel.
    int2 local = int2(tid % (TILE / 2), tid / (TILE / 2));
    int2 p0 = tile_origin + local * 2;
    float a = mip0_value(p0, size);
    float b = mip0_value(p0 + int2(1, 0), size);
    float c = mip0_value(p0 + int2(0, 1), size);
    float d = mip0_value(p0 + int2(1, 1), size);
    store(0, p0, a);
    store(0, p0 + int2(1, 0), b);
    store(0, p0 + int2(0, 1), c);
    store(0, p0 + int2(1, 1), d);
    float m1 = max(max(a, b), max(c, d));
    store(1, tile_origin / 2 + local, m1);
    tile[local.y][local.x] = m1;
    GroupMemoryBarrierWithGroupSync();

    // Mips 2..5 from shared memory, halving the live threads each step.
    uint side = TILE / 2;
    for (uint mip = 2; mip < TILE_MIPS; ++mip) {
        side /= 2;
        float value = 0.0;
        int2 q = int2(tid % side, tid / side);
        bool live = tid < side * side;
        if (live) {
            int2 s = q * 2;
            value = max(max(tile[s.y][s.x], tile[s.y][s.x + 1]),
                        max(tile[s.y + 1][s.x], tile[s.y + 1][s.x + 1]));
            store(mip, (tile_origin >> mip) + q, value);
        }
        GroupMemoryBarrierWithGroupSync();
        if (live) tile[q.y][q.x] = value;
        GroupMemoryBarrierWithGroupSync();
    }

    if (params.mip_count <= TILE_MIPS) return;

    // Publish this group's mip 5 texel, then let the last group finish.
    DeviceMemoryBarrierWithGroupSync();
    if (tid == 0) {
        uint finished;
        InterlockedAdd(finished_groups[params.slot], 1, finished);
        is_last_group = finished == params.group_count - 1;
    }
    GroupMemoryBarrierWithGroupSync();
    if (!is_last_group) return;
    DeviceMemoryBarrier();

    for (uint mip = TILE_MIPS; mip < params.mip_count; ++mip) {
        int2 size = mip_size(mip);
        int2 prev_max = mip_size(mip - 1) - 1;
        for (uint i = tid; i < uint(size.x * size.y); i += 256) {
            int2 q = int2(int(i) % size.x, int(i) / size.x);
            int2 s = q * 2;
            float value = max(
                max(mips(mip - 1)[min(s, prev_max)],
                    mips(mip - 1)[min(s + int2(1, 0), prev_max)]),
                max(mips(mip - 1)[min(s + int2(0, 1), prev_max)],
                    mips(mip - 1)[min(s + int2(1, 1), prev_max)]));
            mips(mip)[q] = value;
        }
        DeviceMemoryBarrierWithGroupSync();
    }
    if (tid == 0) finished_groups[params.slot] = 0;
}
#endif
