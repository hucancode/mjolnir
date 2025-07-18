package navigation

import "core:log"
import "core:math"
import "core:slice"
import "../geometry"

// Compact heightfield structures moved to recast_types.odin
// Using CompactHeightfield, CompactCell, CompactSpan

free_compact_heightfield :: proc(chf: ^CompactHeightfield) {
  if chf == nil do return
  delete(chf.cells)
  delete(chf.spans)
  delete(chf.areas)
  delete(chf.dist)
  free(chf)
}

build_compact_heightfield :: proc(walkable_height, walkable_climb: i32, hf: ^Heightfield, chf: ^CompactHeightfield) -> bool {
  // Count number of walkable cells
  spanCount := 0
  nullCount := 0
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width
      s := hf.spans[idx]
      for s != nil {
        if s.area != NULL_AREA {
          spanCount += 1
        } else {
          nullCount += 1
        }
        s = s.next
      }
    }
  }
  
  log.infof("build_compact_heightfield: Found %d walkable spans, %d null spans", spanCount, nullCount)

  // Initialize compact heightfield
  chf.width = hf.width
  chf.height = hf.height
  chf.span_count = i32(spanCount)
  chf.walkable_height = walkable_height
  chf.walkable_climb = walkable_climb
  chf.max_regions = 0
  chf.bmin = hf.bmin
  chf.bmax = hf.bmax
  chf.cs = hf.cs
  chf.ch = hf.ch
  chf.cells = make([]CompactCell, hf.width * hf.height)
  chf.spans = make([]CompactSpan, spanCount)
  chf.areas = make([]u8, spanCount)
  chf.dist = make([]u16, spanCount)

  // Fill in cells and spans
  idx := 0
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      cellIdx := x + z * hf.width
      s := hf.spans[cellIdx]

      // Set cell index and count
      c := &chf.cells[cellIdx]
      c.index = pack_compact_cell(u32(idx), 0)
      spanCount := u8(0)

      for s != nil {
        if s.area != NULL_AREA {
          bot := s.smax
          top := s.next != nil ? s.next.smin : u32(0xFFFF)

          chf.spans[idx].y = u16(bot)
          chf.spans[idx].reg = 0
          // Initialize all 4 directions to NOT_CONNECTED (0x3F = 63)
          // Each direction uses 6 bits: dir0[0:5], dir1[6:11], dir2[12:17], dir3[18:23]
          con := u32(0x3F) | (u32(0x3F) << 6) | (u32(0x3F) << 12) | (u32(0x3F) << 18)
          chf.spans[idx].con = pack_compact_span(con, u8(min(top - bot, 0xFF)))
          chf.areas[idx] = s.area
          
          // Debug area transfer
          if idx < 10 {
            log.debugf("Compact span %d: area %d (from heightfield span area %d)", idx, chf.areas[idx], s.area)
          }
          
          idx += 1
          spanCount += 1
        }
        s = s.next
      }

      // Update cell count
      cellIndex, _ := unpack_compact_cell(c.index)
      c.index = pack_compact_cell(cellIndex, spanCount)
    }
  }

  // Build connections
  build_compact_heightfield_connections(chf)
  
  // Verify no connections to empty cells were created
  empty_connections := 0
  for y in 0..<chf.height {
    for x in 0..<chf.width {
      c := &chf.cells[x + y * chf.width]
      cellIndex, cellCount := unpack_compact_cell(c.index)
      if cellCount == 0 do continue
      
      for i in cellIndex..<cellIndex + u32(cellCount) {
        s := &chf.spans[i]
        for dir in 0..<4 {
          con_val := get_con(s, dir)
          if con_val != NOT_CONNECTED {
            nx := x + get_dir_offset_x(dir)
            ny := y + get_dir_offset_y(dir)
            if nx >= 0 && ny >= 0 && nx < chf.width && ny < chf.height {
              nc := &chf.cells[nx + ny * chf.width]
              _, ncCount := unpack_compact_cell(nc.index)
              if ncCount == 0 {
                empty_connections += 1
                if empty_connections <= 3 {
                  log.warnf("Connection to empty cell created: (%d,%d) -> (%d,%d)", x, y, nx, ny)
                }
              }
            }
          }
        }
      }
    }
  }
  
  if empty_connections > 0 {
    log.warnf("build_compact_heightfield: Created %d connections to empty cells!", empty_connections)
  }

  return true
}

// Get neighbor connection
get_con :: proc(s: ^CompactSpan, dir: int) -> u16 {
  con, _ := unpack_compact_span(s.con)
  shift := u32(dir * 6)
  return u16((con >> shift) & 0x3F)
}

// Set neighbor connection
set_con :: proc(s: ^CompactSpan, dir: int, i: u16) {
  con, h := unpack_compact_span(s.con)
  shift := u32(dir * 6)
  con = (con & ~(u32(0x3F) << shift)) | (u32(i) << shift)
  s.con = pack_compact_span(con, h)
}

// Direction offsets
get_dir_offset_x :: proc(dir: int) -> i32 {
  offsets := [4]i32{-1, 0, 1, 0}
  return offsets[dir]
}

get_dir_offset_y :: proc(dir: int) -> i32 {
  offsets := [4]i32{0, 1, 0, -1}
  return offsets[dir]
}

build_compact_heightfield_connections :: proc(chf: ^CompactHeightfield) {
  for y in 0..<chf.height {
    for x in 0..<chf.width {
      c := &chf.cells[x + y * chf.width]
      cellIndex, cellCount := unpack_compact_cell(c.index)

      for i in cellIndex..<cellIndex + u32(cellCount) {
        s := &chf.spans[i]

        for dir in 0..<4 {
          set_con(s, dir, NOT_CONNECTED)

          nx := x + get_dir_offset_x(dir)
          ny := y + get_dir_offset_y(dir)
          

          if nx < 0 || ny < 0 || nx >= chf.width || ny >= chf.height {
            continue
          }

          nc := &chf.cells[nx + ny * chf.width]
          ncIndex, ncCount := unpack_compact_cell(nc.index)
          
          // Skip empty cells
          if ncCount == 0 {
            continue
          }

          for k in ncIndex..<ncIndex + u32(ncCount) {
            ns := &chf.spans[k]
            _, sh := unpack_compact_span(s.con)
            _, nsh := unpack_compact_span(ns.con)

            bot := max(s.y, ns.y)
            top := min(i32(s.y) + i32(sh), i32(ns.y) + i32(nsh))

            if (top - i32(bot)) >= chf.walkable_height && abs(i32(ns.y) - i32(s.y)) <= chf.walkable_climb {
              connection_idx := u16(k - ncIndex)
              set_con(s, dir, connection_idx)
              
              
              break
            }
          }
        }
      }
    }
  }
}

// Build a lookup table for span to cell coordinates
// Build coordinate lookup table for distance field
build_span_coords :: proc(chf: ^CompactHeightfield) -> []i32 {
  coords := make([]i32, chf.span_count * 2)

  for y in 0..<chf.height {
    for x in 0..<chf.width {
      c := &chf.cells[x + y * chf.width]
      cellIndex, cellCount := unpack_compact_cell(c.index)
      for i in cellIndex..<cellIndex + u32(cellCount) {
        coords[i * 2] = x
        coords[i * 2 + 1] = y
      }
    }
  }

  return coords
}

build_distance_field :: proc(chf: ^CompactHeightfield) -> bool {
  log.debugf("build_distance_field: Starting with %d spans", chf.span_count)
  
  // Initialize distance field
  for i in 0..<chf.span_count {
    chf.dist[i] = 0xFFFF
  }

  // Build coordinate lookup table
  spanCoords := build_span_coords(chf)
  defer delete(spanCoords)

  // Mark boundary cells
  for i in 0..<chf.span_count {
    x := spanCoords[i * 2]
    y := spanCoords[i * 2 + 1]
    s := &chf.spans[i]
    area := chf.areas[i]

    nc := 0
    for dir in 0..<4 {
      if get_con(s, dir) != NOT_CONNECTED {
        nx := x + get_dir_offset_x(dir)
        ny := y + get_dir_offset_y(dir)

        if nx >= 0 && ny >= 0 && nx < chf.width && ny < chf.height {
          ncIndex, _ := unpack_compact_cell(chf.cells[nx + ny * chf.width].index)
          ni := ncIndex + u32(get_con(s, dir))
          if chf.areas[ni] == area {
            nc += 1
          }
        }
      }
    }

    if nc != 4 {
      chf.dist[i] = 0
    }
  }

  // Initialize queue with boundary cells
  queue := make([dynamic]i32)
  defer delete(queue)

  for i in 0..<chf.span_count {
    if chf.dist[i] == 0 {
      append(&queue, i32(i))
    }
  }

  for len(queue) > 0 {
    ci := queue[0]
    ordered_remove(&queue, 0)

    c := &chf.spans[ci]

    // Use precomputed coordinates
    x := spanCoords[ci * 2]
    y := spanCoords[ci * 2 + 1]

    for dir in 0..<4 {
      if get_con(c, dir) != NOT_CONNECTED {
        nx := x + get_dir_offset_x(dir)
        ny := y + get_dir_offset_y(dir)

        if nx >= 0 && ny >= 0 && nx < chf.width && ny < chf.height {
          ncIndex, _ := unpack_compact_cell(chf.cells[nx + ny * chf.width].index)
          ni := ncIndex + u32(get_con(c, dir))
          newDist := chf.dist[ci] + 2

          if newDist < chf.dist[ni] {
            chf.dist[ni] = newDist
            append(&queue, i32(ni))
          }
        }
      }
    }
  }

  // Store max distance
  maxDist := u16(0)
  boundary_cells := 0
  for i in 0..<chf.span_count {
    if chf.dist[i] == 0 {
      boundary_cells += 1
    }
    if chf.dist[i] != 0xFFFF && chf.dist[i] > maxDist {
      maxDist = chf.dist[i]
    }
  }
  chf.max_distance = maxDist
  
  log.debugf("build_distance_field: Found %d boundary cells, max distance %d", boundary_cells, maxDist)
  
  
  // Apply box blur to smooth the distance field
  blur_distance_field(chf)
  
  return true
}

// Box blur to smooth distance field for better region generation
blur_distance_field :: proc(chf: ^CompactHeightfield) {
  if chf.dist == nil do return
  
  // Allocate temporary buffer
  tmp := make([]u16, chf.span_count)
  defer delete(tmp)
  
  // Apply blur
  for i in 0..<chf.span_count {
    cd := &chf.spans[i]
    
    x, y := get_cell_coords(chf, i32(i))
    if x == -1 || y == -1 {
      tmp[i] = chf.dist[i]
      continue
    }
    
    if chf.areas[i] == NULL_AREA {
      tmp[i] = chf.dist[i]
      continue
    }
    
    total: i32 = 0
    count: i32 = 0
    
    // Sample center
    total += i32(chf.dist[i])
    count += 1
    
    // Sample neighbors
    for dir in 0..<4 {
      if get_con(cd, dir) == NOT_CONNECTED do continue
      
      nx := x + get_dir_offset_x(dir)
      ny := y + get_dir_offset_y(dir)
      
      if nx < 0 || ny < 0 || nx >= chf.width || ny >= chf.height do continue
      
      ncIndex, _ := unpack_compact_cell(chf.cells[nx + ny * chf.width].index)
      ni := i32(ncIndex) + i32(get_con(cd, dir))
      
      if chf.areas[ni] == NULL_AREA do continue
      
      total += i32(chf.dist[ni])
      count += 1
    }
    
    // Average the distance
    tmp[i] = u16((total + count/2) / count)
  }
  
  // Check smoothing effect before copying back
  changes := 0
  total_change := 0
  for i in 0..<chf.span_count {
    if tmp[i] != chf.dist[i] {
      changes += 1
      total_change += abs(int(tmp[i]) - int(chf.dist[i]))
    }
  }
  
  
  // Copy back
  copy(chf.dist[:chf.span_count], tmp[:chf.span_count])
}
