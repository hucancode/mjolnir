package render

import "core:log"
import "core:mem/virtual"
import "core:slice"

// The bytes of an entry of each table render writes. render keeps the one copy
// (Renderer.tables), sized by Config at init and grown past it (table_grow), and marks what it
// writes in Renderer.dirty; tables_sync brings the GPU copies up to date from those each frame.
// The entry layouts are the GPU data contract: every backend's shaders mirror them.
@(private)
TABLE_STRIDES := [Table]int {
  .VIEWS                  = size_of(View),
  .NODES                  = size_of(Node),
  .MESHES                 = size_of(MeshData),
  .MATERIALS              = size_of(Material),
  .BONES                  = size_of(matrix[4, 4]f32),
  .EMITTERS               = size_of(Emitter),
  .FORCE_FIELDS           = size_of(ForceField),
  .LIGHTS                 = size_of(Light),
  .DEBUG_LINES            = size_of(DebugLineSegment),
  .BATCHES                = size_of(Batch),
  .NODE_BATCH             = size_of(u32),
  .SKIN_OWNERS            = size_of(u32),
  .LIGHT_PLACEMENTS       = size_of(LightPlacement),
  .EMITTER_PLACEMENTS     = size_of(EmitterPlacement),
  .FORCE_FIELD_PLACEMENTS = size_of(ForceFieldPlacement),
  .SPRITE_FRAMES          = size_of(SpriteFrame),
}

// The most entries a table may grow to, where something packs its indices into fewer bits:
// first_instance carries a node index in 24 bits (pass_shadow.odin), batch_order a material in
// 24 and a batch in 20 (batches.odin).
@(private)
TABLE_CEILINGS := [Table]int {
  .VIEWS                  = max(int),
  .NODES                  = 1 << 24,
  .MESHES                 = max(int),
  .MATERIALS              = 1 << 24,
  .BONES                  = max(int),
  .EMITTERS               = max(int),
  .FORCE_FIELDS           = max(int),
  .LIGHTS                 = max(int),
  .DEBUG_LINES            = max(int),
  .BATCHES                = 1 << 20,
  .NODE_BATCH             = 1 << 24,
  .SKIN_OWNERS            = max(int),
  .LIGHT_PLACEMENTS       = max(int),
  .EMITTER_PLACEMENTS     = max(int),
  .FORCE_FIELD_PLACEMENTS = max(int),
  .SPRITE_FRAMES          = max(int),
}

// The frame in flight frame records next: it picks this frame's copy of per-frame resources.
@(private)
current_frame :: #force_inline proc(self: ^Renderer) -> u32 {
  return u32(dev.frame_serial(&self.gpu) % FRAMES_IN_FLIGHT)
}

// Callers mark what they change with mark_dirty. Valid until the table next grows.
@(private)
write_table :: #force_inline proc(self: ^Tables, t: Table, $T: typeid) -> []T {
  return slice.reinterpret([]T, self.tables[t])
}

// How many entries table t holds now.
@(private)
table_capacity :: #force_inline proc(self: ^Tables, t: Table) -> int {
  return len(self.tables[t]) / TABLE_STRIDES[t]
}

// The address space a table's entries take, at most: they live in it from init to its ceiling,
// committed as the table grows, so a growing table never moves and a pointer into it (material,
// light, ...) stays valid. Where the platform reserves none (the web) a growing table moves.
@(private = "file")
TABLE_RESERVE_BYTES :: 1 << 32 when size_of(int) == 8 else 0

// What render keeps of each table on the CPU: the entries, the regions written since the last
// submitted frame, and per frame in flight the regions its GPU copy lacks.
@(private)
Tables :: struct {
  // bit r of dirty[t] is region r of tables[t] (TABLE_REGION_BYTES)
  tables:      [Table][]u8,
  // the address space tables[t] grows in; nil where it moves instead
  reserved:    [Table][]u8,
  dirty:       [Table][]u64,
  table_stale: [Table][FRAMES_IN_FLIGHT][]u64,
  // per table, whether anything in dirty or a frame's stale bits is set
  any_dirty:   [Table]bool,
  any_stale:   [Table][FRAMES_IN_FLIGHT]bool,
}

@(private = "file")
region_words :: proc(bytes: int) -> int {
  return (bytes + TABLE_REGION_BYTES * 64 - 1) / (TABLE_REGION_BYTES * 64)
}

@(private)
tables_init :: proc(self: ^Tables, capacities: [Table]int) {
  for t in Table {
    stride := TABLE_STRIDES[t]
    bytes := stride * min(max(capacities[t], 1), TABLE_CEILINGS[t])
    reserved: []u8
    err := virtual.Allocator_Error.Mode_Not_Implemented
    when TABLE_RESERVE_BYTES > 0 {
      reserve := TABLE_RESERVE_BYTES if TABLE_CEILINGS[t] > TABLE_RESERVE_BYTES / stride else TABLE_CEILINGS[t] * stride
      reserved, err = virtual.reserve(uint(reserve))
    }
    if err == nil && virtual.commit(raw_data(reserved), uint(bytes)) == nil {
      self.reserved[t] = reserved
      self.tables[t] = reserved[:bytes]
    } else {
      if err == nil do virtual.release(raw_data(reserved), uint(len(reserved)))
      self.tables[t] = make([]u8, bytes)
    }
    self.dirty[t] = make([]u64, region_words(bytes))
    for &s in self.table_stale[t] do s = make([]u64, region_words(bytes))
  }
}

@(private)
tables_destroy :: proc(self: ^Tables) {
  for t in Table {
    if self.reserved[t] != nil do virtual.release(raw_data(self.reserved[t]), uint(len(self.reserved[t])))
    else do delete(self.tables[t])
    delete(self.dirty[t])
    for s in self.table_stale[t] do delete(s)
  }
  self^ = {}
}

// table_grow makes room for `need` entries, at least doubling, keeping every entry and mark.
// Each frame's GPU copy follows when its frame comes up (tables_reserve). false past the
// table's ceiling.
@(private)
table_grow :: proc(self: ^Tables, t: Table, need: int) -> bool {
  have := table_capacity(self, t)
  if need <= have do return true
  if need > TABLE_CEILINGS[t] {
    log.warnf("Table %v cannot grow past %d entries", t, TABLE_CEILINGS[t])
    return false
  }
  capacity := min(max(need, have * 2), TABLE_CEILINGS[t])
  bytes := capacity * TABLE_STRIDES[t]
  reserved := self.reserved[t]
  if bytes <= len(reserved) && virtual.commit(raw_data(reserved), uint(bytes)) == nil {
    self.tables[t] = reserved[:bytes]
  } else if reserved != nil {
    // past the reservation: the table moves to the heap
    grown := make([]u8, bytes)
    copy(grown, self.tables[t])
    virtual.release(raw_data(reserved), uint(len(reserved)))
    self.tables[t], self.reserved[t] = grown, nil
  } else {
    grow_bytes(&self.tables[t], bytes)
  }
  grow_bits(&self.dirty[t], region_words(bytes))
  for &s in self.table_stale[t] do grow_bits(&s, region_words(bytes))
  return true
}

@(private = "file")
grow_bytes :: proc(s: ^[]u8, n: int) {
  grown := make([]u8, n)
  copy(grown, s^)
  delete(s^)
  s^ = grown
}

@(private = "file")
grow_bits :: proc(s: ^[]u64, n: int) {
  grown := make([]u64, n)
  copy(grown, s^)
  delete(s^)
  s^ = grown
}

// Zeroes `count` entries from `index` and marks them.
@(private)
clear_entry :: proc(self: ^Tables, t: Table, index: u32, count: u32 = 1) {
  if count == 0 do return
  stride := TABLE_STRIDES[t]
  slice.zero(self.tables[t][int(index) * stride:][:int(count) * stride])
  mark_dirty(self, t, int(index), int(count))
}

@(private)
mark_dirty :: #force_inline proc(self: ^Tables, t: Table, index: int, count := 1) {
  if count == 0 do return
  stride := TABLE_STRIDES[t]
  bits := self.dirty[t]
  self.any_dirty[t] = true
  first, last := index * stride / TABLE_REGION_BYTES, ((index + count) * stride - 1) / TABLE_REGION_BYTES
  // one entry spans at most two regions
  if last - first <= 1 {
    bits[first / 64] |= 1 << u64(first % 64)
    bits[last / 64] |= 1 << u64(last % 64)
    return
  }
  for r in first ..= last do bits[r / 64] |= 1 << u64(r % 64)
}

// Writes entry `index` of table t and marks it, only when it changes: for tables rewritten
// whole every frame, so unchanged entries are not uploaded again.
@(private)
write_entry :: #force_inline proc(self: ^Tables, t: Table, index: int, value: $T) {
  entry := &write_table(self, t, T)[index]
  if entry^ == value do return
  entry^ = value
  mark_dirty(self, t, index)
}

// Moves what was marked since the last call into every frame's stale bits: those regions go
// to each GPU copy as its frame comes up.
@(private)
tables_publish :: proc(self: ^Tables) {
  for t in Table {
    if !self.any_dirty[t] do continue
    for &frame, f in self.table_stale[t] {
      for w, i in self.dirty[t] do frame[i] |= w
      self.any_stale[t][f] = true
    }
    slice.zero(self.dirty[t])
    self.any_dirty[t] = false
  }
}

// Marks every region of frame f's copy of table t stale: a new GPU copy.
@(private)
tables_stale_all :: proc(self: ^Tables, t: Table, f: int) {
  regions := (len(self.tables[t]) + TABLE_REGION_BYTES - 1) / TABLE_REGION_BYTES
  stale := self.table_stale[t][f]
  for r in 0 ..< regions do stale[r / 64] |= 1 << u64(r % 64)
  self.any_stale[t][f] = true
}

// tables_next_stale walks the byte ranges [lo, hi) of frame f's stale regions of table t, a run
// of regions each, and clears them once walked:
//   region: int
//   for lo, hi in tables_next_stale(self, t, f, &region) { ... }
@(private)
tables_next_stale :: proc(self: ^Tables, t: Table, f: int, region: ^int) -> (lo, hi: int, ok: bool) {
  if !self.any_stale[t][f] do return
  stale := self.table_stale[t][f]
  size := len(self.tables[t])
  regions := (size + TABLE_REGION_BYTES - 1) / TABLE_REGION_BYTES
  r := region^
  for r < regions {
    if stale[r / 64] == 0 {
      r = (r / 64 + 1) * 64
      continue
    }
    if stale[r / 64] & (1 << u64(r % 64)) == 0 {
      r += 1
      continue
    }
    first := r
    for r < regions && stale[r / 64] & (1 << u64(r % 64)) != 0 do r += 1
    region^ = r
    // the table's end is a 4-byte multiple
    return first * TABLE_REGION_BYTES, min(r * TABLE_REGION_BYTES, size), true
  }
  region^ = r
  slice.zero(stale)
  self.any_stale[t][f] = false
  return
}
