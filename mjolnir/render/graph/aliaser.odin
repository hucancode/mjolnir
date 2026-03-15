package render_graph

import "core:fmt"
import "core:slice"

// ============================================================================
// Resource Aliasing
// ============================================================================
//
// Two virtual resources with non-overlapping lifetimes and compatible Vulkan
// parameters can share the same underlying GPU allocation.
//
// Lifetime: [first_use, last_use] = closed interval of indices into
//   sorted_passes where the resource is first / last accessed (CURRENT only;
//   temporal offsets are excluded because they refer to other frames).
//
// Compatibility: same ResourceType, same Vulkan format / extent / usage /
//   aspect, and the same variant count (both single-buffered or both
//   multi-buffered).
//
// Algorithm: greedy interval-graph coloring (analogous to register allocation).
//   Resources are sorted by first_use.  Each resource either reuses a
//   compatible physical slot whose last_use < current.first_use, or becomes
//   a new physical slot.  Physical slot last_use is extended whenever an alias
//   is assigned so that a third resource cannot incorrectly reuse the same
//   physical resource while an alias is still live.

_ResourceLifetime :: struct {
  first_use: int,
  last_use:  int,
}

_AliasCandidate :: struct {
  id:             ResourceInstanceId,
  first_use:      int,
  last_use:       int,
  wants_variants: bool, // true → allocate frames_in_flight variants
}

_PhysicalSlot :: struct {
  id:             ResourceInstanceId,
  last_use:       int, // Extended each time an alias is assigned to this slot
  wants_variants: bool,
}

// assign_resource_aliases marks compatible, non-overlapping virtual resources
// as aliases of a single physical resource.  Must be called after
// set_execution_order (graph.sorted_passes must be populated).
assign_resource_aliases :: proc(graph: ^Graph) {
  if len(graph.resource_instances) == 0 || len(graph.sorted_passes) == 0 {
    return
  }

  // ── 1. Determine which resources need per-frame variants ──────────────────
  // Mirrors the variant-count logic in allocate_resources so that alias
  // compatibility uses the same variant count the allocator would use.
  needs_frame_variants := _needs_frame_variants(graph)
  defer delete(needs_frame_variants)

  // ── 2. Compute resource lifetimes from sorted_passes ──────────────────────
  // Only CURRENT-frame accesses contribute to the lifetime; temporal accesses
  // (PREV/NEXT) refer to other frame's copies and do not extend liveness.
  lifetimes := make(map[ResourceInstanceId]_ResourceLifetime)
  defer delete(lifetimes)

  for pass_idx in 0 ..< len(graph.sorted_passes) {
    pass_id := graph.sorted_passes[pass_idx]
    pass := get_pass(graph, pass_id)

    for access in pass.reads {
      if access.frame_offset == .CURRENT {
        _touch_lifetime(&lifetimes, graph, access.resource_name, pass_idx)
      }
    }
    for access in pass.writes {
      if access.frame_offset == .CURRENT {
        _touch_lifetime(&lifetimes, graph, access.resource_name, pass_idx)
      }
    }
  }

  // ── 3. Collect non-external candidates, sorted by first_use ──────────────
  candidates := make([dynamic]_AliasCandidate)
  defer delete(candidates)

  for i in 0 ..< len(graph.resource_instances) {
    res := &graph.resource_instances[i]
    res_id := ResourceInstanceId(i)

    if res.is_external {continue}

    lt, has_lt := lifetimes[res_id]
    if !has_lt {continue}   // never accessed (should be dead after elimination)

    wants_variants := needs_frame_variants[res.name]
    if tex, ok := res.data.(ResourceTexture); ok {
      wants_variants = wants_variants || tex.double_buffer
    }

    append(
      &candidates,
      _AliasCandidate {
        id = res_id,
        first_use = lt.first_use,
        last_use = lt.last_use,
        wants_variants = wants_variants,
      },
    )
  }

  slice.sort_by(candidates[:], proc(a, b: _AliasCandidate) -> bool {
    return a.first_use < b.first_use
  })

  // ── 4. Greedy interval coloring ───────────────────────────────────────────
  slots := make([dynamic]_PhysicalSlot)
  defer delete(slots)
  alias_count := 0

  for cand in candidates {
    res := get_resource(graph, cand.id)

    // Find a compatible physical slot that is free before our start
    found_slot := -1
    for slot_idx in 0 ..< len(slots) {
      slot := &slots[slot_idx]
      if slot.last_use >= cand.first_use {continue}   // still in use

      physical := get_resource(graph, slot.id)
      if !_alias_compatible(
        res,
        physical,
        cand.wants_variants,
        slot.wants_variants,
      ) {
        continue
      }

      found_slot = slot_idx
      break
    }

    if found_slot >= 0 {
      res.is_alias = true
      res.alias_target = slots[found_slot].id

      // Extend slot's last_use to cover the alias's lifetime so a third
      // resource cannot incorrectly reuse this physical slot while the alias
      // is still active.
      old_last_use := slots[found_slot].last_use
      if cand.last_use > slots[found_slot].last_use {
        slots[found_slot].last_use = cand.last_use
      }
      alias_count += 1

      when ODIN_DEBUG {
        target := get_resource(graph, slots[found_slot].id)
        log.debugf(
          "[ALIAS] '%s' [%d,%d] → '%s' (slot last_use was %d)\n",
          res.name,
          cand.first_use,
          cand.last_use,
          target.name,
          old_last_use,
        )
      }
    } else {
      // New physical slot
      append(
        &slots,
        _PhysicalSlot {
          id = cand.id,
          last_use = cand.last_use,
          wants_variants = cand.wants_variants,
        },
      )
    }
  }

  when ODIN_DEBUG {
    log.debugf(
      "[ALIAS] %d physical slots, %d aliased, %d total non-external resources\n",
      len(slots),
      alias_count,
      len(candidates),
    )
  }
}

// _touch_lifetime extends [first_use, last_use] for the resource named `name`
// to include `idx`.  No-op if the resource cannot be found.
_touch_lifetime :: proc(
  lifetimes: ^map[ResourceInstanceId]_ResourceLifetime,
  graph: ^Graph,
  name: string,
  idx: int,
) {
  res_id, found := find_resource_by_name(graph, name)
  if !found {return}
  lt, exists := (lifetimes^)[res_id]
  if !exists {
    (lifetimes^)[res_id] = _ResourceLifetime {
      first_use = idx,
      last_use  = idx,
    }
    return
  }
  if idx < lt.first_use {lt.first_use = idx}
  if idx > lt.last_use {lt.last_use = idx}
  (lifetimes^)[res_id] = lt
}

// _alias_compatible returns true when two resources may share the same
// underlying GPU allocation.  Both type and all relevant Vulkan descriptor
// fields must match, plus they must have the same variant count.
_alias_compatible :: proc(
  a, b: ^ResourceInstance,
  a_variants, b_variants: bool,
) -> bool {
  if a_variants != b_variants {return false}

  switch ad in a.data {
  case ResourceBuffer:
    bd, ok := b.data.(ResourceBuffer)
    if !ok {return false}
    return ad.size == bd.size && ad.usage == bd.usage

  case ResourceTexture:
    bt, ok := b.data.(ResourceTexture)
    if !ok {return false}
    return(
      ad.format == bt.format &&
      ad.width == bt.width &&
      ad.height == bt.height &&
      ad.usage == bt.usage &&
      ad.aspect == bt.aspect
    )

  case ResourceTextureCube:
    bct, ok := b.data.(ResourceTextureCube)
    if !ok {return false}
    return(
      ad.format == bct.format &&
      ad.width == bct.width &&
      ad.usage == bct.usage &&
      ad.aspect == bct.aspect
    )
  }

  return false
}
