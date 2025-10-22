package navigation_recast

Span :: struct {
  using data: bit_field u32 {
    smin: u32 | 13,
    smax: u32 | 13,
    area: u32 | 6,
  },
  next: ^Span,
}

Span_Pool :: struct {
  next:  ^Span_Pool,
  items: [RC_SPANS_PER_POOL]Span,
}

Heightfield :: struct {
  width:       i32,
  height:      i32,
  bmin:        [3]f32,
  bmax:        [3]f32,
  cs:          f32,
  ch:          f32,
  spans:       []^Span,
  border_size: i32,
  pools:       ^Span_Pool,
  freelist:    ^Span,
}

Compact_Cell :: bit_field u32 {
  index: u32 | 24,
  count: u8  | 8,
}

Compact_Span :: struct {
  y:   u16,
  reg: u16,
  using data: bit_field u32 {
    con: u32 | 24,
    h:   u8  | 8,
  },
}

Compact_Heightfield :: struct {
  width:           i32,
  height:          i32,
  walkable_height: i32,
  walkable_climb:  i32,
  border_size:     i32,
  max_distance:    u16,
  max_regions:     u16,
  bmin:            [3]f32,
  bmax:            [3]f32,
  cs:              f32,
  ch:              f32,
  cells:           []Compact_Cell,
  spans:           []Compact_Span,
  dist:            []u16,
  areas:           []u8,
}

free_heightfield :: proc(hf: ^Heightfield) {
  if hf == nil do return
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
  delete(chf.cells)
  delete(chf.spans)
  delete(chf.dist)
  delete(chf.areas)
  free(chf)
}

allocate_span :: proc(hf: ^Heightfield) -> ^Span {
  if hf.freelist == nil || hf.freelist.next == nil {
    pool := new(Span_Pool)
    pool.next = hf.pools
    hf.pools = pool
    freelist := hf.freelist
    for i := RC_SPANS_PER_POOL - 1; i >= 0; i -= 1 {
      pool.items[i].next = freelist
      freelist = &pool.items[i]
    }
    hf.freelist = freelist
  }
  new_span := hf.freelist
  hf.freelist = hf.freelist.next
  new_span.next = nil
  return new_span
}

free_span :: proc(hf: ^Heightfield, span: ^Span) {
    if span == nil do return
    span.smin = 0
    span.smax = 0
    span.area = 0
    span.next = hf.freelist
    hf.freelist = span
}

create_heightfield :: proc(width, height: i32, bmin, bmax: [3]f32, cs, ch: f32) -> ^Heightfield {
  hf := new(Heightfield)
  hf.width = width
  hf.height = height
  hf.bmin = bmin
  hf.bmax = bmax
  hf.cs = cs
  hf.ch = ch
  span_count := int(width * height)
  hf.spans = make([]^Span, span_count)
  return hf
}

create_heightfield_from_config :: proc(cfg: ^Config) -> ^Heightfield {
  return create_heightfield(cfg.width, cfg.height, cfg.bmin, cfg.bmax, cfg.cs, cfg.ch)
}

create_compact_heightfield :: proc(walkable_height, walkable_climb: i32, hf: ^Heightfield) -> ^Compact_Heightfield {
  chf := new(Compact_Heightfield)
  if !build_compact_heightfield(walkable_height, walkable_climb, hf, chf) {
    free_compact_heightfield(chf)
    return nil
  }
  return chf
}
