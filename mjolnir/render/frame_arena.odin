package render

import cont "../containers"
import "core:slice"

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
// The frame arena holds one copy of every CPU-written table (TABLES) per frame in flight;
// only the write frame is written, and mark_dirty + hand_off carry writes into the next copy.
@(private)
REGION_COUNT :: 64
@(private)
RegionDebt :: [Table][REGION_COUNT]u8

// The tables render writes: `capacity` entries of `stride` bytes, one copy per frame in flight
// in the backend's frame arena. The entry layouts are the GPU data contract: every backend's
// shaders mirror them.
@(private)
TABLES := [Table]struct {
  stride:   int,
  capacity: int,
} {
  .VIEWS = {size_of(ViewGPU), MAX_VIEWS},
  .NODES = {size_of(NodeData), MAX_NODES_IN_SCENE},
  .MESHES = {size_of(MeshData), MAX_MESHES},
  .MATERIALS = {size_of(Material), MAX_MATERIALS},
  .BONES = {size_of(matrix[4, 4]f32), BONE_CAPACITY},
  .EMITTERS = {size_of(Emitter), MAX_EMITTERS},
  .FORCEFIELDS = {size_of(ForceField), MAX_FORCE_FIELDS},
  .LIGHTS = {size_of(Light), MAX_LIGHTS},
  .DEBUG_LINES = {size_of(DebugLineSegment), MAX_SEGMENTS},
}

@(private)
write_frame :: #force_inline proc(self: ^Renderer) -> u32 {
  return u32(backend_frame_serial(&self.gpu) % FRAMES_IN_FLIGHT)
}

@(private)
frame_table :: proc(self: ^Renderer, t: Table, $T: typeid, frame_index: u32) -> []T {
  return slice.reinterpret([]T, backend_table(&self.gpu, t, frame_index))
}

// Callers mark what they change with mark_dirty.
@(private)
write_table :: #force_inline proc(self: ^Renderer, t: Table, $T: typeid) -> []T {
  return frame_table(self, t, T, write_frame(self))
}

// Zeroes `count` entries of the write table from `index` and marks them.
@(private)
clear_entry :: proc(self: ^Renderer, t: Table, index: u32, count: u32 = 1) {
  if count == 0 do return
  stride := TABLES[t].stride
  slice.zero(backend_table(&self.gpu, t, write_frame(self))[int(index) * stride:][:int(count) * stride])
  mark_dirty(self, t, int(index), int(count))
}

@(private)
mark_dirty :: proc(self: ^Renderer, t: Table, index: int, count := 1) {
  stride := TABLES[t].stride
  region := (len(backend_table(&self.gpu, t, write_frame(self))) + REGION_COUNT - 1) / REGION_COUNT
  first := index * stride / region
  last := min(((index + count) * stride - 1) / region, REGION_COUNT - 1)
  for r in first ..= last do self.region_debt[t][r] = FRAMES_IN_FLIGHT - 1
}

// Call once the backend submitted `from`, which holds every write so far, and freed the next copy.
@(private)
hand_off :: proc(self: ^Renderer, from: u32) {
  to := write_frame(self)
  for t in Table {
    src, dst := backend_table(&self.gpu, t, from), backend_table(&self.gpu, t, to)
    region := (len(src) + REGION_COUNT - 1) / REGION_COUNT
    for &debt, r in self.region_debt[t] {
      if debt == 0 do continue
      debt -= 1
      lo := min(r * region, len(src))
      hi := min(lo + region, len(src))
      copy(dst[lo:hi], src[lo:hi])
    }
  }
}
