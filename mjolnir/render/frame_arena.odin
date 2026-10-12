package render

import cont "../containers"
import "core:mem"
import "gpu"
import vk "vendor:vulkan"

// Starting bone size classes, about 16 MB per frame in flight. Every class
// doubles when one runs out (grow_bones); classes with no blocks never grow.
@(private)
BONE_SLAB_CONFIG :: [cont.MAX_SLAB_CLASSES]struct {
  block_size, block_count: u32,
} {
  {block_size = 32, block_count = 256},
  {block_size = 64, block_count = 256},
  {block_size = 128, block_count = 1024},
  {block_size = 256, block_count = 256},
  {block_size = 512, block_count = 32},
  {block_size = 1024, block_count = 8},
  {block_size = 0, block_count = 0},
  {block_size = 0, block_count = 0},
}

// The scene tables the CPU writes live in host-visible memory, one copy per
// frame in flight: every fixed-size table in one arena buffer, at the offsets
// arena_layout computes, and the bone table, which grows with the bone slab,
// in a buffer of its own.
//
// The copy of the frame recorded next (write_frame) is the only one the CPU
// writes, in place. Render-owned tables (views, lights, debug lines) are
// rewritten every frame. Every other write marks the regions it touched
// (mark_dirty), and after each submission hand_off carries the marked
// regions over into the next frame's copy.
@(private)
FrameTable :: struct {
  binding:  SceneBinding,
  stride:   int,
  capacity: int,
}

@(private)
FRAME_TABLES := [?]FrameTable {
  {.NODES, size_of(NodeData), MAX_NODES_IN_SCENE},
  {.MATERIALS, size_of(Material), MAX_MATERIALS},
  {.EMITTERS, size_of(Emitter), MAX_EMITTERS},
  {.FORCEFIELDS, size_of(ForceField), MAX_FORCE_FIELDS},
  {.LIGHTS, size_of(Light), MAX_LIGHTS},
  {.VIEWS, size_of(ViewGPU), MAX_VIEWS},
  {.DEBUG_LINES, size_of(DebugLineSegment), MAX_SEGMENTS},
}

// Byte range of each arena table; zero for bindings that are not in the
// arena.
@(private)
ArenaLayout :: struct {
  offset: [SceneBinding]vk.DeviceSize,
  range:  [SceneBinding]vk.DeviceSize,
  size:   vk.DeviceSize,
}

// Dirty tracking splits every table into REGION_COUNT equal byte regions.
// Writing a region sets its debt to the frames in flight that miss the write;
// each hand-off copies the regions in debt and pays one off.
@(private)
REGION_COUNT :: 64
@(private)
RegionDebt :: [SceneBinding][REGION_COUNT]u8

@(private)
arena_layout :: proc(alignment: vk.DeviceSize) -> (layout: ArenaLayout) {
  at: vk.DeviceSize
  for t in FRAME_TABLES {
    at = vk.DeviceSize(mem.align_forward_uint(uint(at), uint(alignment)))
    layout.offset[t.binding] = at
    layout.range[t.binding] = vk.DeviceSize(t.stride * t.capacity)
    at += layout.range[t.binding]
  }
  layout.size = at
  return
}

// The frame in flight the CPU writes: the one recorded next.
@(private)
write_frame :: #force_inline proc(self: ^Renderer) -> u32 {
  return u32(self.gctx.frame_serial % gpu.FRAMES_IN_FLIGHT)
}

// Bytes of the bone table: the bone slab's capacity.
@(private)
bone_table_size :: proc(self: ^Renderer) -> int {
  return int(self.bone_matrix_slab.capacity) * size_of(matrix[4, 4]f32)
}

// Frame `frame_index`'s copy of table `b` as bytes.
@(private)
table_bytes :: proc(self: ^Renderer, b: SceneBinding, frame_index: u32) -> []u8 {
  if b == .BONES do return self.bone_buffers[frame_index].mapped[:bone_table_size(self)]
  return self.frame_arena[frame_index].mapped[self.arena_layout.offset[b]:][:self.arena_layout.range[b]]
}

// Frame `frame_index`'s copy of table `b` as `T`s.
@(private)
frame_table :: proc(self: ^Renderer, b: SceneBinding, $T: typeid, frame_index: u32) -> []T {
  bytes := table_bytes(self, b, frame_index)
  return ([^]T)(raw_data(bytes))[:len(bytes) / size_of(T)]
}

// The copy of table `b` the CPU writes. Mark what you change with mark_dirty.
@(private)
write_table :: #force_inline proc(self: ^Renderer, b: SceneBinding, $T: typeid) -> []T {
  return frame_table(self, b, T, write_frame(self))
}

// Mark `count` `T`s from `index` of table `b` written, so they reach every
// other frame in flight.
@(private)
mark_dirty :: proc(self: ^Renderer, b: SceneBinding, $T: typeid, index: int, count := 1) {
  size := bone_table_size(self) if b == .BONES else int(self.arena_layout.range[b])
  region := (size + REGION_COUNT - 1) / REGION_COUNT
  first := index * size_of(T) / region
  last := min(((index + count) * size_of(T) - 1) / region, REGION_COUNT - 1)
  for r in first ..= last do self.region_debt[b][r] = gpu.FRAMES_IN_FLIGHT - 1
}

// Make the frame recorded next the write frame: wait until the GPU is done
// with it, then copy every region in debt from frame `from`, which holds
// every write so far, and pay off one frame of each debt. Call right after
// the submission of `from`.
@(private)
hand_off :: proc(self: ^Renderer, from: u32) -> vk.Result {
  gpu.wait_frame(&self.gctx) or_return
  to := write_frame(self)
  if int(self.bone_buffers[to].size) < bone_table_size(self) {
    // every bone region is in debt since the slab grew
    grow_bone_buffer(self, to) or_return
  }
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
create_bone_buffer :: proc(self: ^Renderer) -> (gpu.Buffer, vk.Result) {
  return gpu.buffer_create(&self.gctx, vk.DeviceSize(bone_table_size(self)), {.STORAGE_BUFFER}, host_cached = true)
}

// Replace frame `frame_index`'s bone buffer with one of the slab's capacity
// and rebind it. The caller guarantees no submitted work still uses it, and
// fills it.
@(private)
grow_bone_buffer :: proc(self: ^Renderer, frame_index: u32) -> vk.Result {
  grown := create_bone_buffer(self) or_return
  gpu.buffer_destroy(self.gctx.device, &self.bone_buffers[frame_index])
  self.bone_buffers[frame_index] = grown
  scene_write_binding(self, .BONES, int(frame_index))
  return .SUCCESS
}

// Allocate the frame arenas and bone buffers (zeroed), the mesh table, the
// pyramid counters and the particle buffers. Paired with
// destroy_scene_buffers. Called once during render.init before
// scene_descriptors_init binds them.
@(private)
init_scene_buffers :: proc(
  self: ^Renderer,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  defer if ret != .SUCCESS do destroy_scene_buffers(self, gctx)
  cont.slab_init(&self.bone_matrix_slab, BONE_SLAB_CONFIG)
  self.arena_layout = arena_layout(gctx.device_properties.limits.minStorageBufferOffsetAlignment)
  for &arena in self.frame_arena {
    arena = gpu.buffer_create(gctx, self.arena_layout.size, {.STORAGE_BUFFER}, host_cached = true) or_return
    mem.zero(arena.mapped, int(arena.size))
  }
  for &bones in self.bone_buffers {
    bones = create_bone_buffer(self) or_return
  }
  self.mesh_data_buffer = gpu.buffer_create(
    gctx,
    MAX_MESHES * size_of(MeshData),
    {.STORAGE_BUFFER},
    host_visible = false,
  ) or_return
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
  for &bones in self.bone_buffers do gpu.buffer_destroy(gctx.device, &bones)
  gpu.buffer_destroy(gctx.device, &self.mesh_data_buffer)
  for &readback in self.draw_count_readback do gpu.buffer_destroy(gctx.device, &readback)
  for &atlas in self.shadow_atlas do gpu.image_destroy(gctx.device, &atlas)
  gpu.buffer_destroy(gctx.device, &self.pyramid_counters)
  gpu.buffer_destroy(gctx.device, &self.particle_buffer)
  gpu.buffer_destroy(gctx.device, &self.particle_alive_buffer)
  cont.slab_destroy(&self.bone_matrix_slab)
}
