package render

import "core:slice"
import "rhi"

// The frame graph: each pass of the frame names the textures and buffers it uses and how;
// compile places the passes into batches in the order they were declared, a pass joining the
// batch before it unless it depends on something there, with one barrier between batches, and
// gives each transient texture a texture of its desc that no overlapping lifetime holds. Only what
// the frame rewrites is tracked: tables, meshes and material textures land with the uploads,
// before the first batch, whose barrier also waits on the previous frame.

@(private)
PassType :: enum u8 {
  COMPUTE,
  RASTER,
  TRANSFER,
}

// How a pass uses a resource. READ and WRITE are a shader's, COPY_SRC and COPY_DST a copy's;
// WRITE_CONCURRENT writes needing no order between them (atomics, appends), ordered like a run of
// reads; COLOR and DEPTH are attachments drawn into, DEPTH_READ one only tested against, INDIRECT
// draw or dispatch arguments.
@(private)
Access :: enum u8 {
  READ,
  WRITE,
  WRITE_CONCURRENT,
  COLOR,
  DEPTH,
  DEPTH_READ,
  INDIRECT,
  COPY_SRC,
  COPY_DST,
}

// What a use names: nothing (a pass slot left empty: it keeps its place among the pass's uses,
// which a record reads back, and orders nothing), a texture or buffer handle, or the index of a
// transient texture.
@(private)
UseKind :: enum u8 {
  NONE,
  TEXTURE,
  BUFFER,
  TRANSIENT,
}

@(private)
GraphUse :: struct {
  handle: u32,
  kind:   UseKind,
  access: Access,
}

// A pass of the frame: uses[first_use:][:use_count], recorded by its kind over arg.
@(private)
GraphPass :: struct {
  name:                 string,
  type:                 PassType,
  kind:                 PassKind,
  arg:                  u32,
  first_use, use_count: u32,
}

// Passes passes[first:][:count]: barrier, and the discard of transient textures
// discards[first_discard:][:discard_count] (physical indices), go before them.
@(private)
GraphBatch :: struct {
  first, count:                 u32,
  barrier:                      rhi.Barrier,
  first_discard, discard_count: u32,
}

// The frame's declarations, then its schedule: transient i lives in physical[placement[i]].
@(private)
FrameGraph :: struct {
  passes:     [dynamic]GraphPass,
  uses:       [dynamic]GraphUse,
  transients: [dynamic]TextureDesc,
  batches:    [dynamic]GraphBatch,
  discards:   [dynamic]u32,
  placement:  [dynamic]u32,
  physical:   [dynamic]TextureDesc,
}

@(private)
GRAPH_NONE :: max(u32)

@(private)
graph_reset :: proc(g: ^FrameGraph) {
  clear(&g.passes)
  clear(&g.uses)
  clear(&g.transients)
}

@(private)
graph_destroy :: proc(g: ^FrameGraph) {
  delete(g.passes)
  delete(g.uses)
  delete(g.transients)
  delete(g.batches)
  delete(g.discards)
  delete(g.placement)
  delete(g.physical)
  g^ = {}
}

// A transient texture of desc: undefined until a pass writes it, gone after the frame.
@(private)
graph_transient :: proc(g: ^FrameGraph, desc: TextureDesc) -> u32 {
  append(&g.transients, desc)
  return u32(len(g.transients) - 1)
}

@(private)
graph_pass :: proc(g: ^FrameGraph, name: string, type: PassType, kind: PassKind, arg: u32, uses: []GraphUse) {
  append(&g.passes, GraphPass{name = name, type = type, kind = kind, arg = arg, first_use = u32(len(g.uses)), use_count = u32(len(uses))})
  append(&g.uses, ..uses)
}

// The stages and memory accesses of `access` in a pass of `type`.
@(private)
access_sync :: proc "contextless" (type: PassType, access: Access) -> (stages: bit_set[rhi.Stage], accesses: bit_set[rhi.Access]) {
  switch access {
  case .READ:
    return SHADER_STAGES[type], {.SHADER_READ}
  case .WRITE, .WRITE_CONCURRENT:
    return SHADER_STAGES[type], {.SHADER_READ, .SHADER_WRITE}
  case .COLOR:
    return {.COLOR_ATTACHMENT_OUTPUT}, {.COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE}
  case .DEPTH:
    return {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}, {.DEPTH_ATTACHMENT_READ, .DEPTH_ATTACHMENT_WRITE}
  case .DEPTH_READ:
    return {.EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS}, {.DEPTH_ATTACHMENT_READ}
  case .INDIRECT:
    return {.DRAW_INDIRECT}, {.INDIRECT_READ}
  case .COPY_SRC:
    return {.TRANSFER}, {.TRANSFER_READ}
  case .COPY_DST:
    return {.TRANSFER}, {.TRANSFER_WRITE}
  }
  return
}

// The accesses that write.
@(private = "file")
WRITES :: bit_set[Access]{.WRITE, .WRITE_CONCURRENT, .COLOR, .DEPTH, .COPY_DST}

// The stages a pass's shaders run in: a TRANSFER pass has none.
@(private = "file")
SHADER_STAGES := #partial [PassType]bit_set[rhi.Stage] {
  .COMPUTE = {.COMPUTE_SHADER},
  .RASTER  = {.VERTEX_SHADER, .FRAGMENT_SHADER},
}

@(private = "file")
ALL_STAGES :: bit_set[rhi.Stage]{.DRAW_INDIRECT, .VERTEX_SHADER, .FRAGMENT_SHADER, .COMPUTE_SHADER, .EARLY_FRAGMENT_TESTS, .LATE_FRAGMENT_TESTS, .COLOR_ATTACHMENT_OUTPUT, .TRANSFER}

@(private = "file")
ALL_ACCESSES :: bit_set[rhi.Access]{.INDIRECT_READ, .SHADER_READ, .SHADER_WRITE, .COLOR_ATTACHMENT_READ, .COLOR_ATTACHMENT_WRITE, .DEPTH_ATTACHMENT_READ, .DEPTH_ATTACHMENT_WRITE, .TRANSFER_READ, .TRANSFER_WRITE}

@(private = "file")
WRITE_ACCESSES :: bit_set[rhi.Access]{.SHADER_WRITE, .COLOR_ATTACHMENT_WRITE, .DEPTH_ATTACHMENT_WRITE, .TRANSFER_WRITE}

// Consecutive uses of one group other than WRITE share a timeline entry: no order between them.
@(private = "file")
Group :: enum u8 {
  NONE,
  READ,
  CONCURRENT,
  WRITE,
}

@(private = "file")
group_of :: proc "contextless" (access: Access) -> Group {
  if access == .WRITE_CONCURRENT do return .CONCURRENT
  return .WRITE if access in WRITES else .READ
}

// The resource a use names, as one u64 for every kind.
@(private = "file")
use_key :: #force_inline proc "contextless" (u: GraphUse) -> u64 {
  return u64(u.kind) << 32 | u64(u.handle)
}

// Schedules the declared passes: each in the batch of the pass before it, or the next one when
// it depends on something there (a read on the last write, a write on every access since); the
// barriers between batches; the discards of transient textures where they begin, and their
// physical textures. A transient texture's first use must write it. A pass using a resource more
// than once uses it once, with every access: a write when any of them writes.
@(private)
graph_compile :: proc(g: ^FrameGraph) {
  clear(&g.batches)
  clear(&g.discards)
  clear(&g.physical)
  resize(&g.placement, len(g.transients))
  slice.fill(g.placement[:], GRAPH_NONE)
  if len(g.passes) == 0 do return
  ids, count := dense_ids(g)
  groups := pass_groups(g, ids, count)
  batch_of := schedule(g, ids, groups, count)
  place(g, batch_of)
  barriers(g, batch_of, ids, groups)
}

// Each use's resource as a dense index below count.
@(private = "file")
dense_ids :: proc(g: ^FrameGraph) -> (ids: []u32, count: int) {
  // [key, use]
  keys := make([][2]u64, len(g.uses), context.temp_allocator)
  for u, i in g.uses do keys[i] = {use_key(u), u64(i)}
  slice.sort_by_key(keys, proc(k: [2]u64) -> u64 {return k[0]})
  ids = make([]u32, len(g.uses), context.temp_allocator)
  for k, i in keys {
    if i > 0 && k[0] != keys[i - 1][0] do count += 1
    ids[k[1]] = u32(count)
  }
  return ids, count + 1
}

// Each use's group, merged over a pass's uses of one resource onto the first of them: theirs when
// they agree, WRITE when not; NONE on the others and on empty slots.
@(private = "file")
pass_groups :: proc(g: ^FrameGraph, ids: []u32, n: int) -> []Group {
  groups := make([]Group, len(g.uses), context.temp_allocator)
  // the use of the resource the pass met first
  first := make([]u32, n, context.temp_allocator)
  slice.fill(first, GRAPH_NONE)
  for p in g.passes do for i in p.first_use ..< p.first_use + p.use_count {
    u := g.uses[i]
    if u.kind == .NONE do continue
    group := group_of(u.access)
    f := first[ids[i]]
    if f == GRAPH_NONE || f < p.first_use {
      first[ids[i]], groups[i] = i, group
    } else if groups[f] != group {
      groups[f] = .WRITE
    }
  }
  return groups
}

@(private = "file")
schedule :: proc(g: ^FrameGraph, ids: []u32, groups: []Group, n: int) -> []u32 {
  kind := make([]Group, n, context.temp_allocator)
  // the last batch of the resource's current timeline entry, and of the one before it
  last := make([]i32, n, context.temp_allocator)
  before := make([]i32, n, context.temp_allocator)
  slice.fill(last, -1)
  slice.fill(before, -1)
  batch_of := make([]u32, len(g.passes), context.temp_allocator)
  b: i32
  for p, pi in g.passes {
    for i in p.first_use ..< p.first_use + p.use_count {
      group, r := groups[i], ids[i]
      if group == .NONE do continue
      assert(kind[r] != .NONE || g.uses[i].kind != .TRANSIENT || group != .READ, "frame graph: a transient texture is read before any pass writes it")
      // joining the entry: depend on the one before it
      dep := before[r] if group != .WRITE && group == kind[r] else last[r]
      b = max(b, dep + 1)
    }
    for i in p.first_use ..< p.first_use + p.use_count {
      group, r := groups[i], ids[i]
      if group == .NONE do continue
      if group != .WRITE && group == kind[r] {
        last[r] = max(last[r], b)
      } else {
        before[r], last[r], kind[r] = last[r], b, group
      }
    }
    batch_of[pi] = u32(b)
  }
  resize(&g.batches, int(b) + 1)
  for batch, pi in batch_of {
    bt := &g.batches[batch]
    if bt.count == 0 do bt.first = u32(pi)
    bt.count += 1
  }
  return batch_of
}

// Each transient, in the order lifetimes begin, takes a physical texture of its desc whose
// tenants have all ended: the fewest textures of each desc that hold them all.
@(private = "file")
place :: proc(g: ^FrameGraph, batch_of: []u32) {
  n := len(g.transients)
  first := make([]u32, n, context.temp_allocator)
  last := make([]u32, n, context.temp_allocator)
  slice.fill(first, GRAPH_NONE)
  for p, pi in g.passes do for u in g.uses[p.first_use:][:p.use_count] {
    if u.kind != .TRANSIENT do continue
    first[u.handle] = min(first[u.handle], batch_of[pi])
    last[u.handle] = max(last[u.handle], batch_of[pi])
  }
  // batch << 32 | transient, in the order lifetimes begin, and in the order they end
  begins := make([dynamic]u64, 0, n, context.temp_allocator)
  for i in 0 ..< n do if first[i] != GRAPH_NONE do append(&begins, u64(first[i]) << 32 | u64(i))
  ends := make([]u64, len(begins), context.temp_allocator)
  for b, i in begins do ends[i] = u64(last[u32(b)]) << 32 | b & 0xFFFFFFFF
  slice.sort(begins[:])
  slice.sort(ends)
  // the ended physical textures of each desc
  free := make(map[TextureDesc][dynamic]u32, context.temp_allocator)
  ended := 0
  for b in begins {
    t := u32(b)
    for ; ended < len(ends) && ends[ended] >> 32 < b >> 32; ended += 1 {
      e := u32(ends[ended])
      list := free[g.transients[e]] or_else make([dynamic]u32, context.temp_allocator)
      append(&list, g.placement[e])
      free[g.transients[e]] = list
    }
    if list, ok := &free[g.transients[t]]; ok && len(list) > 0 {
      g.placement[t] = pop(list)
    } else {
      g.placement[t] = u32(len(g.physical))
      append(&g.physical, g.transients[t])
    }
  }
}

// A pass's uses of one resource, on the resource's timeline (a physical texture's, for a
// transient one).
@(private = "file")
Entry :: struct {
  timeline:        u64,
  batch, pass, id: u32,
  group:           Group,
  stages:          bit_set[rhi.Stage],
  accesses:        bit_set[rhi.Access],
}

// Walks each timeline (a physical texture's tenants one after another): an entry waits on the one
// before it in the batch where it begins, and a tenant's first entry discards. The first batch
// waits on everything recorded before the frame: the previous frame used what this one
// rewrites, and wrote what it reads.
@(private = "file")
barriers :: proc(g: ^FrameGraph, batch_of: []u32, ids: []u32, groups: []Group) {
  g.batches[0].barrier = {src_stage = ALL_STAGES, dst_stage = ALL_STAGES, src_access = WRITE_ACCESSES, dst_access = ALL_ACCESSES}
  entries := make([dynamic]Entry, 0, len(g.uses), context.temp_allocator)
  // the entry of each resource the current pass made
  entry_of := make([]int, len(ids), context.temp_allocator)
  for p, pi in g.passes do for i in p.first_use ..< p.first_use + p.use_count {
    u := g.uses[i]
    if u.kind == .NONE do continue
    if groups[i] != .NONE {
      e := Entry{batch = batch_of[pi], pass = u32(pi), id = ids[i], group = groups[i]}
      e.timeline = u64(UseKind.TRANSIENT) << 32 | u64(g.placement[u.handle]) if u.kind == .TRANSIENT else use_key(u)
      append(&entries, e)
      entry_of[ids[i]] = len(entries) - 1
    }
    // a later use of a resource in the pass adds its stages to the pass's entry
    s, a := access_sync(p.type, u.access)
    entries[entry_of[ids[i]]].stages += s
    entries[entry_of[ids[i]]].accesses += a
  }
  // passes are in batch order, so (timeline, pass) is (timeline, batch, pass)
  slice.sort_by(entries[:], proc(a, b: Entry) -> bool {return a.timeline < b.timeline || (a.timeline == b.timeline && a.pass < b.pass)})
  // batch << 32 | physical
  discards := make([dynamic]u64, 0, context.temp_allocator)
  for i := 0; i < len(entries); {
    head := entries[i]
    prev_stages: bit_set[rhi.Stage]
    prev_accesses: bit_set[rhi.Access]
    has_prev := false
    tenant := GRAPH_NONE
    for i < len(entries) && entries[i].timeline == head.timeline {
      first := entries[i]
      stages, accesses := first.stages, first.accesses
      j := i + 1
      for ; first.group != .WRITE && j < len(entries); j += 1 {
        e := entries[j]
        if e.timeline != first.timeline || e.group != first.group || e.id != first.id do break
        stages += e.stages
        accesses += e.accesses
      }
      bt := &g.batches[first.batch]
      if first.timeline >> 32 == u64(UseKind.TRANSIENT) && first.id != tenant do append(&discards, u64(first.batch) << 32 | first.timeline & 0xFFFFFFFF)
      if has_prev {
        bt.barrier.src_stage += prev_stages
        bt.barrier.dst_stage += stages
        if writes := prev_accesses & WRITE_ACCESSES; writes != {} {
          bt.barrier.src_access += writes
          bt.barrier.dst_access += accesses
        }
      }
      prev_stages, prev_accesses, has_prev = stages, accesses, true
      tenant = first.id
      i = j
    }
  }
  slice.sort(discards[:])
  for d in discards {
    bt := &g.batches[d >> 32]
    if bt.discard_count == 0 do bt.first_discard = u32(len(g.discards))
    append(&g.discards, u32(d))
    bt.discard_count += 1
  }
}
