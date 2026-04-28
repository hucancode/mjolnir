package graph

import "../../gpu"
import "core:log"
import vk "vendor:vulkan"

GraphError :: enum {
  None,
  Cycle,
  AllocFail,
}

graph_compile :: proc(g: ^Graph, gctx: ^gpu.GPUContext) -> (vk.Result, GraphError) {
  build_adjacency(g)
  cull(g)
  if err := topo_sort(g); err != .None {
    return .ERROR_UNKNOWN, err
  }
  compute_lifetimes(g)
  if res := allocate_physical(g, gctx); res != .SUCCESS {
    return res, .AllocFail
  }
  return .SUCCESS, .None
}

build_adjacency :: proc(g: ^Graph) {
  for &r in g.resources {
    clear(&r.producers)
    clear(&r.consumers)
    r.ref_count = 0
    r.first_use = -1
    r.last_use = -1
  }
  for &p, i in g.passes {
    p.ref_count = 0
    p.culled = false
    p.order_index = 0
    for w in p.writes {
      append(&g.resources[w.resource].producers, PassHandle(i))
    }
    for rd in p.reads {
      append(&g.resources[rd.resource].consumers, PassHandle(i))
    }
  }
}

cull :: proc(g: ^Graph) {
  // initial counts
  for &p in g.passes {
    p.ref_count = u32(len(p.writes))
    if p.side_effect {
      p.ref_count += 1
    }
  }
  for &r in g.resources {
    r.ref_count = u32(len(r.consumers))
    if r.imported {
      r.ref_count += 1 // imported resources kept alive
    }
  }
  // stack of unreferenced resources
  stack: [dynamic]ResourceHandle
  defer delete(stack)
  for &r, i in g.resources {
    if r.ref_count == 0 {
      append(&stack, ResourceHandle(i))
    }
  }
  for len(stack) > 0 {
    rh := pop(&stack)
    r := &g.resources[rh]
    for ph in r.producers {
      p := &g.passes[ph]
      if p.ref_count > 0 {
        p.ref_count -= 1
        if p.ref_count == 0 && !p.side_effect {
          // pass culled — drop refs on its reads
          for rd in p.reads {
            cr := &g.resources[rd.resource]
            if cr.ref_count > 0 {
              cr.ref_count -= 1
              if cr.ref_count == 0 {
                append(&stack, rd.resource)
              }
            }
          }
        }
      }
    }
  }
  for &p in g.passes {
    if p.ref_count == 0 && !p.side_effect {
      p.culled = true
    }
  }
}

topo_sort :: proc(g: ^Graph) -> GraphError {
  clear(&g.order)
  // Pass dependencies via shared resources
  in_deg := make([]u32, len(g.passes))
  defer delete(in_deg)
  // edge: producer(prev write) -> consumer(read or later write)
  // simple O(P*R): for each pass, for each read, depend on every producer of that resource
  for &p, i in g.passes {
    if p.culled do continue
    for rd in p.reads {
      for ph in g.resources[rd.resource].producers {
        if int(ph) == i do continue
        if g.passes[ph].culled do continue
        in_deg[i] += 1
      }
    }
    // write-after-write: depend on prior writers (preserve insertion order)
    for w in p.writes {
      for ph in g.resources[w.resource].producers {
        if int(ph) >= i do continue
        if g.passes[ph].culled do continue
        in_deg[i] += 1
      }
    }
  }
  ready: [dynamic]PassHandle
  defer delete(ready)
  for &p, i in g.passes {
    if p.culled do continue
    if in_deg[i] == 0 {
      append(&ready, PassHandle(i))
    }
  }
  // stable Kahn
  for len(ready) > 0 {
    // pick smallest index for stability
    best := 0
    for j in 1 ..< len(ready) {
      if ready[j] < ready[best] {
        best = j
      }
    }
    ph := ready[best]
    ordered_remove(&ready, best)
    g.passes[ph].order_index = u32(len(g.order))
    append(&g.order, ph)
    // decrement consumers
    p := &g.passes[ph]
    for w in p.writes {
      r := &g.resources[w.resource]
      for cph in r.consumers {
        if g.passes[cph].culled do continue
        in_deg[cph] -= 1
        if in_deg[cph] == 0 {
          append(&ready, cph)
        }
      }
      // later writers
      for nph in r.producers {
        if int(nph) <= int(ph) do continue
        if g.passes[nph].culled do continue
        in_deg[nph] -= 1
        if in_deg[nph] == 0 {
          append(&ready, nph)
        }
      }
    }
    // reads also chain to later writers? handled via producers-of-resource above for consumer side
  }
  alive := 0
  for &p in g.passes {
    if !p.culled do alive += 1
  }
  if len(g.order) != alive {
    log.errorf("graph cycle: ordered %d / alive %d", len(g.order), alive)
    return .Cycle
  }
  return .None
}

ordered_remove :: proc(arr: ^[dynamic]PassHandle, i: int) {
  n := len(arr)
  for j in i ..< n - 1 {
    arr[j] = arr[j + 1]
  }
  pop(arr)
}

compute_lifetimes :: proc(g: ^Graph) {
  for ph, idx in g.order {
    p := &g.passes[ph]
    for w in p.writes {
      r := &g.resources[w.resource]
      if r.first_use < 0 do r.first_use = i32(idx)
      r.last_use = i32(idx)
    }
    for rd in p.reads {
      r := &g.resources[rd.resource]
      if r.first_use < 0 do r.first_use = i32(idx)
      r.last_use = i32(idx)
    }
  }
}

allocate_physical :: proc(g: ^Graph, gctx: ^gpu.GPUContext) -> vk.Result {
  // Sweep-line aliasing: process transient image resources in first-use order,
  // assign each one a slot from the pool whose previous tenant finished before
  // this resource's first use. New slots allocated only when none are free.
  // 1) Compute usage flags for every transient image.
  resource_count := len(g.resources)
  usage_per_res := make([]vk.ImageUsageFlags, resource_count, context.temp_allocator)
  defer delete(usage_per_res, context.temp_allocator)
  for &p in g.passes {
    if p.culled do continue
    for w in p.writes {
      usage_per_res[w.resource] |= access_image_usage(w.kind)
    }
    for rd in p.reads {
      usage_per_res[rd.resource] |= access_image_usage(rd.kind)
    }
  }
  // 2) Collect transient image resource indices, sort by first_use ascending.
  transient_idx := make([dynamic]int, 0, resource_count, context.temp_allocator)
  defer delete(transient_idx)
  for &r, i in g.resources {
    if r.imported do continue
    if r.first_use < 0 do continue
    if _, is_image := r.desc.(ImageDesc); !is_image do continue
    append(&transient_idx, i)
  }
  // simple insertion sort by first_use (stable, small N expected)
  for i in 1 ..< len(transient_idx) {
    j := i
    for j > 0 && g.resources[transient_idx[j - 1]].first_use > g.resources[transient_idx[j]].first_use {
      transient_idx[j - 1], transient_idx[j] = transient_idx[j], transient_idx[j - 1]
      j -= 1
    }
  }
  // 3) Acquire slots.
  for ri in transient_idx {
    r := &g.resources[ri]
    d := r.desc.(ImageDesc)
    usage := d.usage_hint | usage_per_res[ri]
    key := ImageKey {
      extent       = d.extent,
      format       = d.format,
      samples      = d.samples,
      array_layers = d.array_layers,
      mip_levels   = d.mip_levels,
      usage        = usage,
      type         = d.type,
    }
    bucket_idx, slot_idx, res := transient_pool_acquire(
      &g.transient_pool, gctx, key, r.first_use,
    )
    if res != .SUCCESS do return res
    bucket := &g.transient_pool.buckets[bucket_idx]
    slot := &bucket.slots[slot_idx]
    slot.available_after = r.last_use
    r.alias_slot = i32(slot_idx)
    r.physical = slot.image
    // Slot images survive across frames, but each new tenant sees UNDEFINED
    // contents (the prior tenant's data is invalidated by re-aliasing).
    r.current_layout = .UNDEFINED
    r.last_stage = {}
    r.last_access = {}
  }
  return .SUCCESS
}
