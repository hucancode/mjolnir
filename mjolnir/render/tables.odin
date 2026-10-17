package render

import "../containers"
import "core:slice"

// About 16 MB per frame in flight.
@(private)
BONE_SLAB_CONFIG :: containers.SlabConfig {
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

// The skinned vertex ranges, one per skinned node, as many vertices as its mesh: about 24 MB.
@(private)
SKIN_SLAB_CONFIG :: containers.SlabConfig {
  {block_size = 1024, block_count = 64},
  {block_size = 4096, block_count = 32},
  {block_size = 16384, block_count = 16},
  {block_size = 65536, block_count = 2},
  {block_size = 0, block_count = 0},
  {block_size = 0, block_count = 0},
  {block_size = 0, block_count = 0},
  {block_size = 0, block_count = 0},
}
// vertices in the skinned vertex buffer and the skin owner table: the slab's capacity
@(private)
SKIN_CAPACITY ::
  int(SKIN_SLAB_CONFIG[0].block_size * SKIN_SLAB_CONFIG[0].block_count) +
  int(SKIN_SLAB_CONFIG[1].block_size * SKIN_SLAB_CONFIG[1].block_count) +
  int(SKIN_SLAB_CONFIG[2].block_size * SKIN_SLAB_CONFIG[2].block_count) +
  int(SKIN_SLAB_CONFIG[3].block_size * SKIN_SLAB_CONFIG[3].block_count)
#assert(SKIN_SLAB_CONFIG[4].block_count == 0)

// The tables render writes: `capacity` entries of `stride` bytes. render keeps the one copy
// (Renderer.tables) and marks what it writes in Renderer.dirty; tables_sync brings the GPU
// copies up to date from those each frame. The entry layouts are the GPU data contract: every
// backend's shaders mirror them.
@(private)
TABLES := [Table]struct {
  stride:   int,
  capacity: int,
} {
  .VIEWS = {size_of(View), MAX_VIEWS},
  .NODES = {size_of(Node), MAX_SLOTS},
  .MESHES = {size_of(MeshData), MAX_MESHES},
  .MATERIALS = {size_of(Material), MAX_MATERIALS},
  .BONES = {size_of(matrix[4, 4]f32), BONE_CAPACITY},
  .EMITTERS = {size_of(Emitter), MAX_EMITTERS},
  .FORCE_FIELDS = {size_of(ForceField), MAX_FORCE_FIELDS},
  .LIGHTS = {size_of(Light), MAX_LIGHTS},
  .DEBUG_LINES = {size_of(DebugLineSegment), MAX_SEGMENTS},
  .BATCHES = {size_of(Batch), MAX_BATCHES},
  .NODE_BATCH = {size_of(u32), MAX_SLOTS},
  .SKIN_OWNERS = {size_of(u32), SKIN_CAPACITY},
  .LIGHT_PLACEMENTS = {size_of(LightPlacement), MAX_LIGHTS},
  .EMITTER_PLACEMENTS = {size_of(EmitterPlacement), MAX_EMITTERS},
  .FORCE_FIELD_PLACEMENTS = {size_of(ForceFieldPlacement), MAX_FORCE_FIELDS},
}

// The frame in flight frame records next: it picks this frame's copy of per-frame resources.
@(private)
current_frame :: #force_inline proc(self: ^Renderer) -> u32 {
  return u32(dev.frame_serial(&self.gpu) % FRAMES_IN_FLIGHT)
}

// Callers mark what they change with mark_dirty.
@(private)
write_table :: #force_inline proc(self: ^Renderer, t: Table, $T: typeid) -> []T {
  return slice.reinterpret([]T, self.tables[t])
}

// Zeroes `count` entries from `index` and marks them.
@(private)
clear_entry :: proc(self: ^Renderer, t: Table, index: u32, count: u32 = 1) {
  if count == 0 do return
  stride := TABLES[t].stride
  slice.zero(self.tables[t][int(index) * stride:][:int(count) * stride])
  mark_dirty(self, t, int(index), int(count))
}

@(private)
mark_dirty :: proc(self: ^Renderer, t: Table, index: int, count := 1) {
  if count == 0 do return
  stride := TABLES[t].stride
  region := (len(self.tables[t]) + TABLE_REGIONS - 1) / TABLE_REGIONS
  first := index * stride / region
  last := min(((index + count) * stride - 1) / region, TABLE_REGIONS - 1)
  for r in first ..= last do self.dirty[t] |= 1 << u64(r)
}
