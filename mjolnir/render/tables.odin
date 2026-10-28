package render

import "core:slice"

// MAX_BONES is the bone matrices of every palette (bones_create) together: 4 MB per frame in
// flight at the default, about 950 palettes of a 69-bone character (-define:MAX_BONES=n).
MAX_BONES :: #config(MAX_BONES, 1 << 16)

// MAX_SKINNED_VERTICES is the vertices of every skinned mesh attached at once, each slot its
// own: 96 MB at the default, about 130 characters of 16k vertices or 650 of 3k
// (-define:MAX_SKINNED_VERTICES=n).
MAX_SKINNED_VERTICES :: #config(MAX_SKINNED_VERTICES, 1 << 21)

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
  .BONES = {size_of(matrix[4, 4]f32), MAX_BONES},
  .EMITTERS = {size_of(Emitter), MAX_EMITTERS},
  .FORCE_FIELDS = {size_of(ForceField), MAX_FORCE_FIELDS},
  .LIGHTS = {size_of(Light), MAX_LIGHTS},
  .DEBUG_LINES = {size_of(DebugLineSegment), MAX_SEGMENTS},
  .BATCHES = {size_of(Batch), MAX_BATCHES},
  .NODE_BATCH = {size_of(u32), MAX_SLOTS},
  .SKIN_OWNERS = {size_of(u32), MAX_SKINNED_VERTICES},
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
mark_dirty :: #force_inline proc(self: ^Renderer, t: Table, index: int, count := 1) {
  if count == 0 do return
  stride := TABLES[t].stride
  bits := self.dirty[t]
  first, last := index * stride / TABLE_REGION_BYTES, ((index + count) * stride - 1) / TABLE_REGION_BYTES
  // one entry spans at most two regions
  if last - first <= 1 {
    bits[first / 64] |= 1 << u64(first % 64)
    bits[last / 64] |= 1 << u64(last % 64)
    return
  }
  for r in first ..= last do bits[r / 64] |= 1 << u64(r % 64)
}
