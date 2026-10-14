package render

import cont "../containers"
import "core:mem"
import "core:slice"
import "gpu"
import vk "vendor:vulkan"

// About 16 MB per frame in flight.
@(private)
BONE_SLAB_CONFIG :: cont.SlabConfig {
  {block_size = 32, block_count = 256},
  {block_size = 64, block_count = 256},
  {block_size = 128, block_count = 1024},
  {block_size = 256, block_count = 256},
  {block_size = 512, block_count = 32},
  {block_size = 1024, block_count = 8},
  {block_size = 0, block_count = 0},
  {block_size = 0, block_count = 0},
}
// matrices in the bone table: the slab's capacity
@(private)
BONE_CAPACITY ::
  int(BONE_SLAB_CONFIG[0].block_size * BONE_SLAB_CONFIG[0].block_count) +
  int(BONE_SLAB_CONFIG[1].block_size * BONE_SLAB_CONFIG[1].block_count) +
  int(BONE_SLAB_CONFIG[2].block_size * BONE_SLAB_CONFIG[2].block_count) +
  int(BONE_SLAB_CONFIG[3].block_size * BONE_SLAB_CONFIG[3].block_count) +
  int(BONE_SLAB_CONFIG[4].block_size * BONE_SLAB_CONFIG[4].block_count) +
  int(BONE_SLAB_CONFIG[5].block_size * BONE_SLAB_CONFIG[5].block_count)
#assert(BONE_SLAB_CONFIG[6].block_count == 0 && BONE_SLAB_CONFIG[7].block_count == 0)

// A write sets its regions' debt to the frames that miss it; each hand_off pays one off.
// The frame arena holds one copy of every CPU-written table (BINDINGS) per frame in flight;
// only the write frame is written, and mark_dirty + hand_off carry writes into the next copy.
@(private)
REGION_COUNT :: 64
@(private)
RegionDebt :: [SceneBinding][REGION_COUNT]u8

@(private)
table_range :: proc(b: SceneBinding) -> vk.DeviceSize {
  return vk.DeviceSize(BINDINGS[b].stride * BINDINGS[b].capacity)
}

// Offset of each binding's table in the arena; every table is aligned.
@(private)
arena_layout :: proc(alignment: vk.DeviceSize) -> (offset: [SceneBinding]vk.DeviceSize, size: vk.DeviceSize) {
  for b in SceneBinding {
    size = vk.DeviceSize(mem.align_forward_uint(uint(size), uint(alignment)))
    offset[b] = size
    size += table_range(b)
  }
  return
}

@(private)
write_frame :: #force_inline proc(self: ^Renderer) -> u32 {
  return u32(self.gctx.frame_serial % gpu.FRAMES_IN_FLIGHT)
}

// Empty for a binding outside the arena.
@(private)
table_bytes :: proc(self: ^Renderer, b: SceneBinding, frame_index: u32) -> []u8 {
  return self.frame_arena[frame_index].mapped[self.arena_offset[b]:][:table_range(b)]
}

@(private)
frame_table :: proc(self: ^Renderer, b: SceneBinding, $T: typeid, frame_index: u32) -> []T {
  bytes := table_bytes(self, b, frame_index)
  return ([^]T)(raw_data(bytes))[:len(bytes) / size_of(T)]
}

// Callers mark what they change with mark_dirty.
@(private)
write_table :: #force_inline proc(self: ^Renderer, b: SceneBinding, $T: typeid) -> []T {
  return frame_table(self, b, T, write_frame(self))
}

// Zeroes entry `index` of the write table and marks it.
@(private)
clear_entry :: proc(self: ^Renderer, b: SceneBinding, index: u32) {
  stride := BINDINGS[b].stride
  slice.zero(table_bytes(self, b, write_frame(self))[int(index) * stride:][:stride])
  mark_dirty(self, b, int(index))
}

@(private)
mark_dirty :: proc(self: ^Renderer, b: SceneBinding, index: int, count := 1) {
  stride := BINDINGS[b].stride
  region := (int(table_range(b)) + REGION_COUNT - 1) / REGION_COUNT
  first := index * stride / region
  last := min(((index + count) * stride - 1) / region, REGION_COUNT - 1)
  for r in first ..= last do self.region_debt[b][r] = gpu.FRAMES_IN_FLIGHT - 1
}

// Call right after submitting `from`, which holds every write so far.
@(private)
hand_off :: proc(self: ^Renderer, from: u32) -> vk.Result {
  gpu.wait_frame(&self.gctx) or_return
  to := write_frame(self)
  for b in SceneBinding {
    src, dst := table_bytes(self, b, from), table_bytes(self, b, to)
    region := (len(src) + REGION_COUNT - 1) / REGION_COUNT
    for &debt, r in self.region_debt[b] {
      if debt == 0 do continue
      debt -= 1
      lo := min(r * region, len(src))
      hi := min(lo + region, len(src))
      copy(dst[lo:hi], src[lo:hi])
    }
  }
  return .SUCCESS
}

@(private)
init_scene_buffers :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  defer if ret != .SUCCESS do destroy_scene_buffers(self, gctx)
  cont.slab_init(&self.bone_matrix_slab, BONE_SLAB_CONFIG)
  arena_size: vk.DeviceSize
  self.arena_offset, arena_size = arena_layout(gctx.device_properties.limits.minStorageBufferOffsetAlignment)
  for &arena in self.frame_arena {
    arena = gpu.buffer_create(gctx, arena_size, {.STORAGE_BUFFER}, host_cached = true) or_return
    mem.zero(arena.mapped, int(arena.size))
  }
  for &readback in self.draw_count_readback {
    readback = gpu.buffer_create(gctx, DRAW_LIST_HEADER * size_of(u32), {.TRANSFER_DST}) or_return
  }
  self.pyramid_counters = gpu.buffer_create(gctx, MAX_PYRAMID_SLOTS * size_of(u32), {.STORAGE_BUFFER}, host_visible = false) or_return
  gpu.queue_buffer_fill(gctx, &self.pyramid_counters)
  particles_init_buffers(self) or_return
  for &atlas in self.shadow_atlas do atlas = shadow_atlas_create(gctx, 1) or_return
  return .SUCCESS
}

@(private)
destroy_scene_buffers :: proc(self: ^Renderer, gctx: ^gpu.GPUContext) {
  for &arena in self.frame_arena do gpu.buffer_destroy(gctx.device, &arena)
  for &readback in self.draw_count_readback do gpu.buffer_destroy(gctx.device, &readback)
  for &atlas in self.shadow_atlas do gpu.image_destroy(gctx.device, &atlas)
  gpu.buffer_destroy(gctx.device, &self.pyramid_counters)
  gpu.buffer_destroy(gctx.device, &self.particle_buffer)
  gpu.buffer_destroy(gctx.device, &self.particle_alive_buffer)
  cont.slab_destroy(&self.bone_matrix_slab)
}
