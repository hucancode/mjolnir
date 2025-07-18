package navigation

import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "../geometry"

// Heightfield structures now in recast_types.odin
// Using Heightfield, Span, SpanPool

create_height_field :: proc(width, height: i32, bmin, bmax: [3]f32, cs, ch: f32) -> ^Heightfield {
  hf := new(Heightfield)
  hf.width = width
  hf.height = height
  hf.bmin = bmin
  hf.bmax = bmax
  hf.cs = cs
  hf.ch = ch
  hf.spans = make([]^Span, width * height)
  hf.pools = nil
  hf.freelist = nil
  return hf
}

free_height_field :: proc(hf: ^Heightfield) {
  if hf == nil do return
  // Free all pools
  pool := hf.pools
  for pool != nil {
    next := pool.next
    free(pool)
    pool = next
  }
  delete(hf.spans)
  free(hf)
}

// Helper function to calculate height range for a triangle
calc_height_range :: proc(v0, v1, v2: [3]f32, hf: ^Heightfield) -> (u32, u32) {
  min_y := min(v0.y, v1.y, v2.y)
  max_y := max(v0.y, v1.y, v2.y)

  smin := u32(max(0, (min_y - hf.bmin.y) / hf.ch))
  smax := u32(max(0, (max_y - hf.bmin.y) / hf.ch))

  // Clamp to span max height
  if smax > SPAN_MAX_HEIGHT {
    smax = SPAN_MAX_HEIGHT
  }

  return smin, smax
}

// Allocate span from pool
alloc_span :: proc(hf: ^Heightfield) -> ^Span {
  // If freelist is empty, allocate new pool
  if hf.freelist == nil {
    pool := new(SpanPool)
    pool.next = hf.pools
    hf.pools = pool

    // Add all spans in pool to freelist
    for i := SPANS_PER_POOL-1; i >= 0; i -= 1 {
      pool.items[i].next = hf.freelist
      hf.freelist = &pool.items[i]
    }
  }

  // Pop from freelist
  span := hf.freelist
  hf.freelist = span.next
  return span
}

// Free span back to pool
free_span :: proc(hf: ^Heightfield, span: ^Span) {
  if span == nil do return
  span.next = hf.freelist
  hf.freelist = span
}

// Add span to column
add_span :: proc(hf: ^Heightfield, x, z: i32, smin, smax: u32, area: u8, flagMergeThr: i32 = -1) {
  idx := x + z * hf.width
  if idx < 0 || idx >= i32(len(hf.spans)) do return

  s := alloc_span(hf)
  s.smin = smin
  s.smax = smax
  s.area = area
  s.next = nil
  
  // Debug span creation (only for center samples)
  if x == hf.width/2 && z == hf.height/2 {
    log.debugf("add_span: center (%d,%d) height %d-%d area %d", x, z, smin, smax, area)
  }
  
  // Debug: Track NULL_AREA spans
  if area == NULL_AREA && x == hf.width/2 && z == hf.height/2 {
    log.debugf("add_span: Adding NULL_AREA span at center (%d,%d) height %d-%d", x, z, smin, smax)
  }

  // Empty column, add first span
  if hf.spans[idx] == nil {
    hf.spans[idx] = s
    return
  }

  prev: ^Span = nil
  cur := hf.spans[idx]

  // Insert span in order
  for cur != nil {
    if cur.smin > s.smax {
      // Insert before current
      break
    }
    if cur.smax < s.smin {
      // Continue searching
      prev = cur
      cur = cur.next
      continue
    }

    // Spans overlap, merge
    if cur.smin < s.smin do s.smin = cur.smin
    if cur.smax > s.smax do s.smax = cur.smax

    // Merge flags
    if abs(i32(s.smax) - i32(cur.smax)) <= flagMergeThr {
      // Merge area if within threshold
      if cur.area != NULL_AREA do s.area = cur.area
    }

    // Remove current span
    next := cur.next
    free_span(hf, cur)
    if prev != nil {
      prev.next = next
    } else {
      hf.spans[idx] = next
    }
    cur = next
  }

  // Insert span
  if prev != nil {
    s.next = prev.next
    prev.next = s
  } else {
    s.next = hf.spans[idx]
    hf.spans[idx] = s
  }
}

rasterize_triangle :: proc(hf: ^Heightfield, v0, v1, v2: [3]f32, area: u8, flagMergeThr: i32 = -1) {
  tmin := [3]f32{min(v0.x, v1.x, v2.x), min(v0.y, v1.y, v2.y), min(v0.z, v1.z, v2.z)}
  tmax := [3]f32{max(v0.x, v1.x, v2.x), max(v0.y, v1.y, v2.y), max(v0.z, v1.z, v2.z)}

  x0 := i32((tmin.x - hf.bmin.x) / hf.cs)
  x1 := i32((tmax.x - hf.bmin.x) / hf.cs)
  z0 := i32((tmin.z - hf.bmin.z) / hf.cs)
  z1 := i32((tmax.z - hf.bmin.z) / hf.cs)
  

  x0 = clamp(x0, 0, hf.width - 1)
  x1 = clamp(x1, 0, hf.width - 1)
  z0 = clamp(z0, 0, hf.height - 1)
  z1 = clamp(z1, 0, hf.height - 1)

  for z in z0..=z1 {
    for x in x0..=x1 {
      cell_min := [2]f32{
        hf.bmin.x + f32(x) * hf.cs,
        hf.bmin.z + f32(z) * hf.cs,
      }
      cell_max := cell_min + [2]f32{hf.cs, hf.cs}

      if !triangle_overlaps_box_2d(v0.xz, v1.xz, v2.xz, cell_min, cell_max) {
        continue
      }

      smin, smax := calc_height_range(v0, v1, v2, hf)
      add_span(hf, x, z, smin, smax, area, flagMergeThr)
    }
  }
}

rasterize_triangles :: proc(hf: ^Heightfield, verts: []f32, tris: []i32, areas: []u8, ntris: int, flagMergeThr: i32 = -1) {
  walkable_count := 0
  null_count := 0
  
  for i in 0..<ntris {
    idx0 := tris[i*3+0]
    idx1 := tris[i*3+1]
    idx2 := tris[i*3+2]
    
    // Debug first few and any problematic triangles
    if i < 5 || (i >= 30 && i <= 35) {
      log.debugf("Triangle %d: indices %d, %d, %d", i, idx0, idx1, idx2)
    }
    
    // Debug bounds check
    max_vert_idx := (len(verts) / 3) - 1
    if idx0 > i32(max_vert_idx) || idx1 > i32(max_vert_idx) || idx2 > i32(max_vert_idx) {
      log.errorf("Triangle %d has invalid vertex indices: %d, %d, %d (max: %d)", i, idx0, idx1, idx2, max_vert_idx)
      continue
    }
    
    v0 := [3]f32{verts[idx0*3+0], verts[idx0*3+1], verts[idx0*3+2]}
    v1 := [3]f32{verts[idx1*3+0], verts[idx1*3+1], verts[idx1*3+2]}
    v2 := [3]f32{verts[idx2*3+0], verts[idx2*3+1], verts[idx2*3+2]}

    area: u8 = WALKABLE_AREA
    if areas != nil && i < len(areas) {
      area = areas[i]
    }
    
    if area == WALKABLE_AREA {
      walkable_count += 1
    } else if area == NULL_AREA {
      null_count += 1
    }

    rasterize_triangle(hf, v0, v1, v2, area, flagMergeThr)
  }
  
  log.infof("rasterize_triangles: Rasterized %d walkable triangles, %d null area triangles out of %d total", 
    walkable_count, null_count, ntris)
}

filter_lowHanging_walkable_obstacles :: proc(walkable_climb: i32, hf: ^Heightfield) {
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width
      s := hf.spans[idx]

      for s != nil {
        bot := i32(s.smax)
        top := s.next != nil ? i32(s.next.smin) : max(i32)

        if top - bot <= walkable_climb {
          s.area = NULL_AREA
        }
        s = s.next
      }
    }
  }
}

filter_ledge_spans :: proc(walkable_height, walkable_climb: i32, hf: ^Heightfield) {
  // Direction offsets for N, E, S, W neighbors
  dx := [4]i32{0, 1, 0, -1}
  dz := [4]i32{-1, 0, 1, 0}

  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width

      s := hf.spans[idx]
      for s != nil {
        if s.area == NULL_AREA {
          s = s.next
          continue
        }

        bot := i32(s.smax)
        top := s.next != nil ? i32(s.next.smin) : max(i32)

        // Find neighbors minimum floor
        minh := max(i32)

        // Check all 4 neighbors
        for dir in 0..<4 {
          nx := x + dx[dir]
          nz := z + dz[dir]

          // Skip if neighbor is out of bounds
          if nx < 0 || nz < 0 || nx >= hf.width || nz >= hf.height do continue

          nidx := nx + nz * hf.width
          ns := hf.spans[nidx]

          // Find minimum floor
          for ns != nil {
            nbot := i32(ns.smax)
            ntop := ns.next != nil ? i32(ns.next.smin) : max(i32)

            // Skip non-walkable neighbors
            if ns.area == NULL_AREA {
              ns = ns.next
              continue
            }

            // Check if the neighbor span is accessible
            if nbot - bot > walkable_climb {
              minh = min(minh, nbot - bot)
            }
            ns = ns.next
          }
        }

        // The span is ledge if it's significantly higher than all neighbors
        if minh > walkable_climb {
          s.area = NULL_AREA
        }

        s = s.next
      }
    }
  }
}

filter_walkable_low_height_spans :: proc(walkable_height: i32, hf: ^Heightfield) {
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width

      s := hf.spans[idx]
      for s != nil {
        if s.area == NULL_AREA {
          s = s.next
          continue
        }

        bot := i32(s.smax)
        top := s.next != nil ? i32(s.next.smin) : max(i32)

        if top - bot < walkable_height {
          s.area = NULL_AREA
        }

        s = s.next
      }
    }
  }
}
