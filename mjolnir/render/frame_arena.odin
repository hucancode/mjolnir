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

// The scene tables written by the CPU every frame live in one host-visible
// buffer per frame in flight, one table after another at the offsets
// arena_layout computes. Bones come last: their table grows with the bone
// slab and takes the rest of the buffer.
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
  {.LIGHTS, size_of(LightGPU), MAX_LIGHTS},
  {.VIEWS, size_of(ViewGPU), MAX_VIEWS},
  {.BONES, size_of(matrix[4, 4]f32), 0},
}

// Byte range of each frame table in a frame arena; zero for bindings that are
// not frame tables. The bone table starts at `offset[.BONES]`.
@(private)
ArenaLayout :: struct {
  offset: [SceneBinding]vk.DeviceSize,
  range:  [SceneBinding]vk.DeviceSize,
}

@(private)
arena_layout :: proc(alignment: vk.DeviceSize) -> (layout: ArenaLayout) {
  at: vk.DeviceSize
  for t in FRAME_TABLES {
    at = vk.DeviceSize(mem.align_forward_uint(uint(at), uint(alignment)))
    layout.offset[t.binding] = at
    layout.range[t.binding] = vk.DeviceSize(t.stride * t.capacity)
    at += layout.range[t.binding]
  }
  return
}

// Frame `frame_index`'s table `b` as `T`s; the bone table runs to the end of
// the arena.
@(private)
frame_table :: proc(self: ^Manager, b: SceneBinding, $T: typeid, frame_index: u32) -> []T {
  arena := &self.internal.frame_arena[frame_index]
  layout := &self.internal.arena_layout
  if b == .BONES do return gpu.mapped(arena, T, layout.offset[.BONES])
  return gpu.mapped(arena, T, layout.offset[b], int(layout.range[b]) / size_of(T))
}

@(private)
create_frame_arena :: proc(self: ^Manager, bone_capacity: int) -> (gpu.Buffer, vk.Result) {
  size := self.internal.arena_layout.offset[.BONES] +vk.DeviceSize(bone_capacity * size_of(matrix[4, 4]f32))
  return gpu.buffer_create(&self.gctx, size, {.STORAGE_BUFFER})
}

// Allocate the frame arenas, the mesh table and the particle buffers. Paired
// with destroy_scene_buffers. Called once during render.init before
// scene_descriptors_init binds them.
@(private)
init_scene_buffers :: proc(
  self: ^Manager,
  gctx: ^gpu.GPUContext,
) -> (
  ret: vk.Result,
) {
  defer if ret != .SUCCESS do destroy_scene_buffers(self, gctx)
  cont.slab_init(&self.internal.bone_matrix_slab, BONE_SLAB_CONFIG)
  self.internal.arena_layout = arena_layout(gctx.device_properties.limits.minStorageBufferOffsetAlignment)
  for &arena in self.internal.frame_arena {
    arena = create_frame_arena(self, int(self.internal.bone_matrix_slab.capacity)) or_return
  }
  self.internal.mesh_data_buffer = gpu.buffer_create(
    gctx,
    MAX_MESHES * size_of(MeshData),
    {.STORAGE_BUFFER},
    host_visible = false,
  ) or_return
  for &readback in self.internal.draw_count_readback {
    readback = gpu.buffer_create(gctx, DRAW_LIST_HEADER * size_of(u32), {.TRANSFER_DST}) or_return
  }
  particles_init_buffers(&self.internal.particles, gctx) or_return
  for &atlas in self.internal.shadow_atlas do shadow_atlas_init(&atlas, gctx, 1) or_return
  return .SUCCESS
}

@(private)
destroy_scene_buffers :: proc(self: ^Manager, gctx: ^gpu.GPUContext) {
  for &arena in self.internal.frame_arena do gpu.buffer_destroy(gctx.device, &arena)
  gpu.buffer_destroy(gctx.device, &self.internal.mesh_data_buffer)
  for &readback in self.internal.draw_count_readback do gpu.buffer_destroy(gctx.device, &readback)
  for &atlas in self.internal.shadow_atlas do shadow_atlas_destroy(&atlas, gctx.device)
  particles_destroy_buffers(&self.internal.particles, gctx)
  cont.slab_destroy(&self.internal.bone_matrix_slab)
}

// Replace frame `frame_index`'s arena with one whose bone table holds
// `bone_capacity` matrices, keeping every other table's contents, and rebind
// it. The caller guarantees no submitted work still uses that frame's arena
// or scene set.
@(private)
grow_frame_arena :: proc(self: ^Manager, frame_index: u32, bone_capacity: int) -> vk.Result {
  grown := create_frame_arena(self, bone_capacity) or_return
  arena := &self.internal.frame_arena[frame_index]
  mem.copy(grown.mapped, arena.mapped, int(self.internal.arena_layout.offset[.BONES]))
  gpu.buffer_destroy(self.gctx.device, arena)
  arena^ = grown
  for t in FRAME_TABLES do scene_write_binding(self, t.binding, int(frame_index))
  return .SUCCESS
}
