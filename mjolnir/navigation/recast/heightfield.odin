package navigation_recast


// Represents a span in a heightfield.
Rc_Span :: struct {
  // Bit field for packed data matching C++ layout
  using data: bit_field u32 {
    smin: u32 | 13, // The lower extent of the span
    smax: u32 | 13, // The upper extent of the span
    area: u32 | 6, // The area id assigned to the span
  },
  next:       ^Rc_Span, // The next span higher up in column
}


// A memory pool used for quick allocation of spans within a heightfield.
Rc_Span_Pool :: struct {
  next:  ^Rc_Span_Pool, // The next span pool
  items: [RC_SPANS_PER_POOL]Rc_Span, // Array of spans in the pool
}

// A dynamic heightfield representing obstructed space.
Rc_Heightfield :: struct {
  width:       i32, // The width of the heightfield (Along the x-axis in cell units)
  height:      i32, // The height of the heightfield (Along the z-axis in cell units)
  bmin:        [3]f32, // The minimum bounds in world space [(x, y, z)]
  bmax:        [3]f32, // The maximum bounds in world space [(x, y, z)]
  cs:          f32, // The size of each cell (On the xz-plane)
  ch:          f32, // The height of each cell (The minimum increment along the y-axis)
  spans:       []^Rc_Span, // Heightfield of spans (width*height) - using slice instead of **
  border_size: i32, // Border size used during generation
  // Memory pool for rcSpan instances
  pools:       ^Rc_Span_Pool, // Linked list of span pools
  freelist:    ^Rc_Span, // The next free span
}

// Provides information on the content of a cell column in a compact heightfield.
Rc_Compact_Cell :: bit_field u32 {
  // In C++: unsigned int index : 24 (24 bits)
  // unsigned int count : 8 (8 bits)
  index: u32 | 24,
  count: u8  | 8,
}

// Represents a span of unobstructed space within a compact heightfield.
Rc_Compact_Span :: bit_field u64 {
  y:   u16 | 16, // The lower extent of the span (Measured from the heightfield's base)
  reg: u16 | 16, // The id of the region the span belongs to (Or zero if not in a region)
  con: u32 | 24,
  h:   u8  | 8,
}

// A compact, static heightfield representing unobstructed space.
Rc_Compact_Heightfield :: struct {
  width:           i32, // The width of the heightfield (Along the x-axis in cell units)
  height:          i32, // The height of the heightfield (Along the z-axis in cell units)
  span_count:      i32, // The number of spans in the heightfield
  walkable_height: i32, // The walkable height used during the build of the field
  walkable_climb:  i32, // The walkable climb used during the build of the field
  border_size:     i32, // The AABB border size used during the build of the field
  max_distance:    u16, // The maximum distance value of any span within the field
  max_regions:     u16, // The maximum region id of any span within the field
  bmin:            [3]f32, // The minimum bounds in world space [(x, y, z)]
  bmax:            [3]f32, // The maximum bounds in world space [(x, y, z)]
  cs:              f32, // The size of each cell (On the xz-plane)
  ch:              f32, // The height of each cell (The minimum increment along the y-axis)
  cells:           []Rc_Compact_Cell, // Array of cells [Size: width*height]
  spans:           []Rc_Compact_Span, // Array of spans [Size: span_count]
  dist:            []u16, // Array containing border distance data [Size: span_count]
  areas:           []u8, // Array containing area id data [Size: span_count]
}

// Allocation helpers

alloc_heightfield :: proc() -> ^Rc_Heightfield {
  hf := new(Rc_Heightfield)
  return hf
}

free_heightfield :: proc(hf: ^Rc_Heightfield) {
  if hf == nil do return

  // Free all span pools
  pool := hf.pools
  for pool != nil {
    next := pool.next
    free(pool)
    pool = next
  }

  // Free the spans array
  if hf.spans != nil {
    delete(hf.spans)
  }

  // Free the heightfield itself
  free(hf)
}

alloc_compact_heightfield :: proc() -> ^Rc_Compact_Heightfield {
  chf := new(Rc_Compact_Heightfield)
  return chf
}

free_compact_heightfield :: proc(chf: ^Rc_Compact_Heightfield) {
  if chf == nil do return

  // Free all arrays
  delete(chf.cells)
  delete(chf.spans)
  delete(chf.dist)
  delete(chf.areas)

  // Free the compact heightfield itself
  free(chf)
}

// Initialize a heightfield with the given dimensions
init_heightfield :: proc(
  hf: ^Rc_Heightfield,
  width, height: i32,
  bmin, bmax: [3]f32,
  cs, ch: f32,
) -> bool {
  hf.width = width
  hf.height = height
  hf.bmin = bmin
  hf.bmax = bmax
  hf.cs = cs
  hf.ch = ch

  // Allocate spans array
  span_count := int(width * height)
  hf.spans = make([]^Rc_Span, span_count)
  if hf.spans == nil {
    return false
  }

  // Initialize all spans to nil
  for i in 0 ..< span_count {
    hf.spans[i] = nil
  }

  return true
}

// Allocate a new span from the pool
alloc_span :: proc(hf: ^Rc_Heightfield) -> ^Rc_Span {
  // If there's a span in the freelist, use it
  if hf.freelist != nil {
    span := hf.freelist
    hf.freelist = span.next
    return span
  }

  // Otherwise, allocate from the pool
  // If all pools are exhausted, allocate a new pool
  if hf.pools == nil || all_spans_used(hf.pools) {
    pool := new(Rc_Span_Pool)
    if pool == nil do return nil

    pool.next = hf.pools
    hf.pools = pool

    // Add all spans from the new pool to the freelist
    // Link them in reverse order so we can iterate efficiently
    for i := RC_SPANS_PER_POOL - 1; i >= 0; i -= 1 {
      pool.items[i].next = hf.freelist
      hf.freelist = &pool.items[i]
    }
  }

  // Now use the freelist (which should have spans from the new pool)
  if hf.freelist != nil {
    span := hf.freelist
    hf.freelist = span.next
    return span
  }

  // Should not reach here if pool allocation worked correctly
  return nil
}

// Helper to check if all spans in pools are used
all_spans_used :: proc(pools: ^Rc_Span_Pool) -> bool {
  // Walk through all pools and check if any have available spans
  for current_pool := pools; current_pool != nil; current_pool = current_pool.next {
    // For simplicity, we check if there are spans that could be available
    if current_pool != nil {
      // If pools exist but we need proper tracking, return false for now
      // This will trigger new pool allocation when needed
      return true
    }
  }
  return true
}

// Create heightfield
rc_create_heightfield :: proc(
  hf: ^Rc_Heightfield,
  width, height: i32,
  bmin, bmax: [3]f32,
  cs, ch: f32,
) -> bool {
  return init_heightfield(hf, width, height, bmin, bmax, cs, ch)
}

// Create heightfield from configuration - returns heightfield and success status
rc_create_heightfield_from_config :: proc(
  cfg: ^Config,
) -> (
  hf: ^Rc_Heightfield,
  success: bool,
) {
  hf = rc_alloc_heightfield()
  if hf == nil do return nil, false

  success = rc_create_heightfield(
    hf,
    cfg.width,
    cfg.height,
    cfg.bmin,
    cfg.bmax,
    cfg.cs,
    cfg.ch,
  )
  if !success {
    rc_free_heightfield(hf)
    return nil, false
  }

  return hf, true
}

// Build compact heightfield from heightfield - returns compact heightfield and success status
rc_build_compact_heightfield_from_hf :: proc(
  walkable_height, walkable_climb: i32,
  hf: ^Rc_Heightfield,
) -> (
  chf: ^Rc_Compact_Heightfield,
  success: bool,
) {
  chf = rc_alloc_compact_heightfield()
  if chf == nil do return nil, false

  // Need to import the builder module
  success = rc_build_compact_heightfield(
    walkable_height,
    walkable_climb,
    hf,
    chf,
  )
  if !success {
    rc_free_compact_heightfield(chf)
    return nil, false
  }

  return chf, true
}

// Allocator wrappers with standard naming
rc_alloc_heightfield :: proc() -> ^Rc_Heightfield {
  return alloc_heightfield()
}

rc_free_heightfield :: proc(hf: ^Rc_Heightfield) {
  free_heightfield(hf)
}

rc_alloc_compact_heightfield :: proc() -> ^Rc_Compact_Heightfield {
  return alloc_compact_heightfield()
}

rc_free_compact_heightfield :: proc(chf: ^Rc_Compact_Heightfield) {
  free_compact_heightfield(chf)
}

// Connection utilities for compact spans
get_con :: proc "contextless" (s: Rc_Compact_Span, dir: u8) -> u8 {
  shift := dir * 6
  return u8((s.con >> shift) & 0x3f)
}
