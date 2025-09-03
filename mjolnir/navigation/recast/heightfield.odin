package navigation_recast

// Represents a span in a heightfield.
Span :: struct {
  using data: bit_field u32 {
    smin: u32 | 13, // The lower extent of the span
    smax: u32 | 13, // The upper extent of the span
    area: u32 | 6, // The area id assigned to the span
  },
  next:       ^Span, // The next span higher up in column
}

// A memory pool used for quick allocation of spans within a heightfield.
Span_Pool :: struct {
  next:  ^Span_Pool, // The next span pool
  items: [RC_SPANS_PER_POOL]Span, // Array of spans in the pool
}

// A dynamic heightfield representing obstructed space.
Heightfield :: struct {
  width:       i32, // The width of the heightfield (Along the x-axis in cell units)
  height:      i32, // The height of the heightfield (Along the z-axis in cell units)
  bmin:        [3]f32, // The minimum bounds in world space [(x, y, z)]
  bmax:        [3]f32, // The maximum bounds in world space [(x, y, z)]
  cs:          f32, // The size of each cell (On the xz-plane)
  ch:          f32, // The height of each cell (The minimum increment along the y-axis)
  spans:       []^Span, // Heightfield of spans (width*height) - using slice instead of **
  border_size: i32, // Border size used during generation
  // Memory pool for rcSpan instances
  pools:       ^Span_Pool, // Linked list of span pools
  freelist:    ^Span, // The next free span
}

// Provides information on the content of a cell column in a compact heightfield.
Compact_Cell :: bit_field u32 {
  index: u32 | 24,
  count: u8  | 8,
}

// Represents a span of unobstructed space within a compact heightfield.
Compact_Span :: struct {
  y:   u16, // The lower extent of the span (Measured from the heightfield's base)
  reg: u16, // The id of the region the span belongs to (Or zero if not in a region)
  using data: bit_field u32 {
    con: u32 | 24, // Packed neighbor connection data
    h:   u8  | 8,  // The height of the span (Measured from y)
  },
}

// A compact, static heightfield representing unobstructed space.
Compact_Heightfield :: struct {
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
  cells:           []Compact_Cell, // Array of cells [Size: width*height]
  spans:           []Compact_Span, // Array of spans [Size: span_count]
  dist:            []u16, // Array containing border distance data [Size: span_count]
  areas:           []u8, // Array containing area id data [Size: span_count]
}

free_heightfield :: proc(hf: ^Heightfield) {
  if hf == nil do return
  // Free all span pools
  pool := hf.pools
  for pool != nil {
    next := pool.next
    free(pool)
    pool = next
  }
  delete(hf.spans)
  free(hf)
}

free_compact_heightfield :: proc(chf: ^Compact_Heightfield) {
  if chf == nil do return

  // Free all arrays
  delete(chf.cells)
  delete(chf.spans)
  delete(chf.dist)
  delete(chf.areas)

  // Free the compact heightfield itself
  free(chf)
}

// Allocate a new span from the pool
allocate_span :: proc(hf: ^Heightfield) -> ^Span {
  // If necessary, allocate new page and update the freelist
  if hf.freelist == nil || hf.freelist.next == nil {
    // Create new page
    // Allocate memory for the new pool
    pool := new(Span_Pool)
    if pool == nil do return nil

    // Add the pool into the list of pools
    pool.next = hf.pools
    hf.pools = pool

    // Add new spans to the free list
    freelist := hf.freelist
    head := &pool.items[0]
    it := &pool.items[RC_SPANS_PER_POOL - 1]

    // Link all items in reverse order
    for i := RC_SPANS_PER_POOL - 1; i >= 0; i -= 1 {
      pool.items[i].next = freelist
      freelist = &pool.items[i]
    }
    hf.freelist = freelist
  }

  // Pop item from the front of the free list
  new_span := hf.freelist
  hf.freelist = hf.freelist.next
  // Clear the next pointer to avoid stale references
  new_span.next = nil
  return new_span
}

// Releases the memory used by the span back to the heightfield
free_span :: proc(hf: ^Heightfield, span: ^Span) {
    if span == nil {
        return
    }
    // Clear span data before adding to freelist
    span.smin = 0
    span.smax = 0
    span.area = 0
    // Add the span to the front of the free list
    span.next = hf.freelist
    hf.freelist = span
}

// Span cache for recently accessed columns
Span_Column_Cache :: struct {
    column_index: i32,
    first_span: ^Span,
    span_count: i32,
    last_access: u32,
}

// Create heightfield
create_heightfield :: proc(
  hf: ^Heightfield,
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
  span_count := int(width * height)
  hf.spans = make([]^Span, span_count)
  if hf.spans == nil {
    return false
  }
  for i in 0 ..< span_count {
    hf.spans[i] = nil
  }
  return true
}

// Create heightfield from configuration - returns heightfield and success status
create_heightfield_from_config :: proc(
  cfg: ^Config,
) -> (
  hf: ^Heightfield,
  success: bool,
) {
  hf = new(Heightfield)
  if hf == nil do return nil, false

  success = create_heightfield(
    hf,
    cfg.width,
    cfg.height,
    cfg.bmin,
    cfg.bmax,
    cfg.cs,
    cfg.ch,
  )
  if !success {
    free_heightfield(hf)
    return nil, false
  }

  return hf, true
}

// Build compact heightfield from heightfield - returns compact heightfield and success status
build_compact_heightfield_from_hf :: proc(
  walkable_height, walkable_climb: i32,
  hf: ^Heightfield,
) -> (
  chf: ^Compact_Heightfield,
  success: bool,
) {
  chf = new(Compact_Heightfield)
  if chf == nil do return nil, false

  // Need to import the builder module
  ok := build_compact_heightfield(
    walkable_height,
    walkable_climb,
    hf,
    chf,
  )
  if !ok {
    free_compact_heightfield(chf)
    return nil, false
  }

  return chf, true
}
