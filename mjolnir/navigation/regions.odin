package navigation

import "core:log"
import "core:math"
import "core:slice"
import "../geometry"

// Region structures for internal processing
Region :: struct {
  id:           u16,
  area:         i32,
  remap:        bool,
  visited:      bool,
  overlap:      bool,
  connections:  [dynamic]u16,
  floors:       [dynamic]i32,
}

// Level stack entry for watershed algorithm
LevelStackEntry :: struct {
  x, y:  i32,
  index: i32,
}

// Build regions using the watershed algorithm (matching Recast)
build_regions :: proc(chf: ^CompactHeightfield, borderSize, minRegionArea, mergeRegionArea: i32) -> bool {
  // Distance field should already be built
  if chf.dist == nil {
    log.error("build_regions: Distance field not built")
    return false
  }
  
  log.infof("build_regions: Starting watershed algorithm with %d spans", chf.span_count)
  
  // Region generation working correctly
  
  w := chf.width
  h := chf.height
  
  // Allocate region and distance arrays
  buf := make([]u16, chf.span_count * 2)
  defer delete(buf)
  
  srcReg := buf[0:chf.span_count]
  srcDist := buf[chf.span_count:chf.span_count*2]
  
  // Initialize arrays
  for i in 0..<chf.span_count {
    srcReg[i] = 0
    srcDist[i] = 0
  }
  
  regionId: u16 = 1
  level := u16((chf.max_distance + 1) & ~u16(1))
  
  // Starting watershed algorithm
  
  // Expansion iterations - controls how much regions "overflow"
  expandIters := 8
  
  // Mark border regions if needed
  if borderSize > 0 {
    bw := min(w, borderSize)
    bh := min(h, borderSize)
    
    // Paint border regions
    paint_rect_region(0, bw, 0, h, regionId | BORDER_REG, chf, srcReg)
    regionId += 1
    paint_rect_region(w-bw, w, 0, h, regionId | BORDER_REG, chf, srcReg)
    regionId += 1
    paint_rect_region(0, w, 0, bh, regionId | BORDER_REG, chf, srcReg)
    regionId += 1
    paint_rect_region(0, w, h-bh, h, regionId | BORDER_REG, chf, srcReg)
    regionId += 1
  }
  
  chf.border_size = borderSize
  
  // Level stacks for sorting cells by distance
  LOG_NB_STACKS :: 3
  NB_STACKS :: 1 << LOG_NB_STACKS
  lvlStacks: [NB_STACKS][dynamic]LevelStackEntry
  for i in 0..<NB_STACKS {
    lvlStacks[i] = make([dynamic]LevelStackEntry)
    reserve(&lvlStacks[i], 256)
  }
  defer {
    for i in 0..<NB_STACKS {
      delete(lvlStacks[i])
    }
  }
  
  stack := make([dynamic]LevelStackEntry)
  defer delete(stack)
  reserve(&stack, 256)
  
  sId := -1
  iteration := 0
  for level > 0 {
    level = level >= 2 ? level - 2 : 0
    sId = (sId + 1) & (NB_STACKS - 1)
    
    if sId == 0 {
      sort_cells_by_level(level, chf, srcReg, NB_STACKS, &lvlStacks, 1)
    } else {
      append_stacks(&lvlStacks[sId-1], &lvlStacks[sId], srcReg)
    }
    
    // Processing level %d
    
    // Expand current regions until no empty connected cells found
    expand_regions(expandIters, level, chf, srcReg, srcDist, &lvlStacks[sId], false)
    
    // Mark new regions with IDs
    regions_created := 0
    for j in 0..<len(lvlStacks[sId]) {
      current := lvlStacks[sId][j]
      x := current.x
      y := current.y
      i := current.index
      
      if i >= 0 && srcReg[i] == 0 {
        if flood_region(x, y, i, level, regionId, chf, srcReg, srcDist, &stack) {
          if regionId == 0xFFFF {
            log.error("build_regions: Region ID overflow")
            return false
          }
          regionId += 1
          regions_created += 1
        }
      }
    }
    
    // Created regions for this level
    iteration += 1
  }
  
  // Final expansion pass - this should assign boundary spans
  expand_regions(expandIters * 8, 0, chf, srcReg, srcDist, &stack, true)
  
  // Store result
  for i in 0..<chf.span_count {
    chf.spans[i].reg = srcReg[i]
  }
  
  chf.max_regions = regionId
  
  log.infof("build_regions: Before merging - max region id: %d", regionId)
  
  // Merge small regions
  merge_small_regions(chf, minRegionArea, mergeRegionArea)
  
  // Count final regions
  final_regions := 0
  maxRegion: u16 = 0
  for i in 0..<chf.span_count {
    if chf.spans[i].reg > maxRegion {
      maxRegion = chf.spans[i].reg
    }
  }
  
  // Count unique regions
  region_sizes := make([]i32, maxRegion + 1)
  defer delete(region_sizes)
  
  for i in 0..<chf.span_count {
    if chf.spans[i].reg > 0 {
      region_sizes[chf.spans[i].reg] += 1
    }
  }
  
  for i in 1..=maxRegion {
    if region_sizes[i] > 0 {
      final_regions += 1
    }
  }
  
  log.infof("build_regions: Final region count: %d", final_regions)
  
  return true
}

// Paint a rectangular region
paint_rect_region :: proc(minx, maxx, miny, maxy: i32, regId: u16, chf: ^CompactHeightfield, srcReg: []u16) {
  w := chf.width
  for y in miny..<maxy {
    for x in minx..<maxx {
      c := &chf.cells[x + y * w]
      cIndex, cCount := unpack_compact_cell(c.index)
      for i in cIndex..<(cIndex + u32(cCount)) {
        if chf.areas[i] != NULL_AREA {
          srcReg[i] = regId
        }
      }
    }
  }
}

// Sort cells by distance level
sort_cells_by_level :: proc(startLevel: u16, chf: ^CompactHeightfield, srcReg: []u16, 
                            nbStacks: int, stacks: ^[8][dynamic]LevelStackEntry, 
                            loglevelsPerStack: int) {
  w := chf.width
  h := chf.height
  startLevelShifted := startLevel >> u16(loglevelsPerStack)
  
  for j in 0..<nbStacks {
    clear(&stacks[j])
  }
  
  // Put all cells in the level range into the appropriate stacks
  for y in 0..<h {
    for x in 0..<w {
      c := &chf.cells[x + y * w]
      cIndex, cCount := unpack_compact_cell(c.index)
      
      for i in cIndex..<(cIndex + u32(cCount)) {
        if chf.areas[i] == NULL_AREA || srcReg[i] != 0 {
          continue
        }
        
        level := chf.dist[i] >> u16(loglevelsPerStack)
        sId := int(startLevelShifted) - int(level)
        if sId >= nbStacks {
          continue
        }
        if sId < 0 {
          sId = 0
        }
        
        append(&stacks[sId], LevelStackEntry{x, y, i32(i)})
      }
    }
  }
}

// Append one stack to another
append_stacks :: proc(srcStack, dstStack: ^[dynamic]LevelStackEntry, srcReg: []u16) {
  for j in 0..<len(srcStack) {
    i := srcStack[j].index
    if i < 0 || srcReg[i] != 0 {
      continue
    }
    append(dstStack, srcStack[j])
  }
}

// Expand regions - this is the key watershed algorithm
expand_regions :: proc(maxIter: int, level: u16, chf: ^CompactHeightfield, 
                       srcReg, srcDist: []u16, stack: ^[dynamic]LevelStackEntry, 
                       fillStack: bool) {
  w := chf.width
  h := chf.height
  
  if fillStack {
    // Find cells revealed by the raised level
    clear(stack)
    cells_added := 0
    for y in 0..<h {
      for x in 0..<w {
        c := &chf.cells[x + y * w]
        cIndex, cCount := unpack_compact_cell(c.index)
        
        for i in cIndex..<(cIndex + u32(cCount)) {
          if chf.dist[i] >= level && srcReg[i] == 0 && chf.areas[i] != NULL_AREA {
            append(stack, LevelStackEntry{x, y, i32(i)})
            cells_added += 1
          }
        }
      }
    }
    // Final expansion complete
  } else {
    // Mark all cells which already have a region
    for j in 0..<len(stack) {
      i := stack[j].index
      if srcReg[i] != 0 {
        stack[j].index = -1
      }
    }
  }
  
  dirtyEntries := make([dynamic]struct{index: i32, region: u16, distance2: u16})
  defer delete(dirtyEntries)
  
  iter := 0
  for len(stack) > 0 {
    failed := 0
    clear(&dirtyEntries)
    
    for j in 0..<len(stack) {
      x := stack[j].x
      y := stack[j].y
      i := stack[j].index
      
      if i < 0 {
        failed += 1
        continue
      }
      
      r: u16 = srcReg[i]
      d2: u16 = 0xFFFF
      area := chf.areas[i]
      s := &chf.spans[i]
      
      // Check neighbors for regions to expand from
      for dir in 0..<4 {
        if get_con(s, dir) == NOT_CONNECTED {
          continue
        }
        
        ax := x + get_dir_offset_x(dir)
        ay := y + get_dir_offset_y(dir)
        acIndex, _ := unpack_compact_cell(chf.cells[ax + ay * w].index)
        ai := i32(acIndex) + i32(get_con(s, dir))
        
        if chf.areas[ai] != area {
          continue
        }
        
        if srcReg[ai] > 0 && (srcReg[ai] & BORDER_REG) == 0 {
          if u32(srcDist[ai]) + 2 < u32(d2) {
            r = srcReg[ai]
            d2 = srcDist[ai] + 2
          }
        }
      }
      
      if r != 0 {
        stack[j].index = -1  // Mark as used
        append(&dirtyEntries, struct{index: i32, region: u16, distance2: u16}{i, r, d2})
      } else {
        failed += 1
      }
    }
    
    // Copy entries that differ between src and dst to keep them in sync
    for entry in dirtyEntries {
      idx := entry.index
      srcReg[idx] = entry.region
      srcDist[idx] = entry.distance2
    }
    
    if failed == len(stack) {
      break
    }
    
    if level > 0 {
      iter += 1
      if iter >= maxIter {
        break
      }
    }
  }
}

// Flood fill a region
flood_region :: proc(x, y, i: i32, level: u16, r: u16, 
                     chf: ^CompactHeightfield, srcReg, srcDist: []u16, 
                     stack: ^[dynamic]LevelStackEntry) -> bool {
  w := chf.width
  area := chf.areas[i]
  
  // Flood fill mark region
  clear(stack)
  append(stack, LevelStackEntry{x, y, i})
  srcReg[i] = r
  srcDist[i] = 0
  
  lev := level >= 2 ? level - 2 : 0
  count := 0
  
  for len(stack) > 0 {
    back := pop(stack)
    cx := back.x
    cy := back.y
    ci := back.index
    
    cs := &chf.spans[ci]
    
    // Check if any of the neighbors already have a valid region set
    ar: u16 = 0
    for dir in 0..<4 {
      if get_con(cs, dir) != NOT_CONNECTED {
        ax := cx + get_dir_offset_x(dir)
        ay := cy + get_dir_offset_y(dir)
        acIndex, _ := unpack_compact_cell(chf.cells[ax + ay * w].index)
        ai := i32(acIndex) + i32(get_con(cs, dir))
        
        if chf.areas[ai] != area {
          continue
        }
        
        nr := srcReg[ai]
        if (nr & BORDER_REG) != 0 {  // Do not take borders into account
          continue
        }
        
        if nr != 0 && nr != r {
          ar = nr
          break
        }
        
        // Check diagonal
        as := &chf.spans[ai]
        dir2 := (dir + 1) & 0x3
        if get_con(as, dir2) != NOT_CONNECTED {
          ax2 := ax + get_dir_offset_x(dir2)
          ay2 := ay + get_dir_offset_y(dir2)
          a2cIndex, _ := unpack_compact_cell(chf.cells[ax2 + ay2 * w].index)
          ai2 := i32(a2cIndex) + i32(get_con(as, dir2))
          
          if chf.areas[ai2] != area {
            continue
          }
          
          nr2 := srcReg[ai2]
          if nr2 != 0 && nr2 != r {
            ar = nr2
            break
          }
        }
      }
    }
    
    if ar != 0 {
      srcReg[ci] = 0
      continue
    }
    
    count += 1
    
    // Expand neighbors
    for dir in 0..<4 {
      if get_con(cs, dir) != NOT_CONNECTED {
        ax := cx + get_dir_offset_x(dir)
        ay := cy + get_dir_offset_y(dir)
        acIndex, _ := unpack_compact_cell(chf.cells[ax + ay * w].index)
        ai := i32(acIndex) + i32(get_con(cs, dir))
        
        if chf.areas[ai] != area {
          continue
        }
        
        if chf.dist[ai] >= lev && srcReg[ai] == 0 {
          srcReg[ai] = r
          srcDist[ai] = 0
          append(stack, LevelStackEntry{ax, ay, ai})
        }
      }
    }
  }
  
  return count > 0
}

// Previously existing functions remain unchanged
find_distance_seed :: proc(chf: ^CompactHeightfield, srcReg: []u16) -> i32 {
  maxDist: u16 = 0
  seedId: i32 = -1
  
  for i in 0..<chf.span_count {
    if chf.dist[i] < 4 do continue
    if srcReg[i] != 0 do continue
    if chf.areas[i] == NULL_AREA do continue
    
    if chf.dist[i] > maxDist {
      maxDist = chf.dist[i]
      seedId = i32(i)
    }
  }
  
  return seedId
}

get_cell_coords :: proc(chf: ^CompactHeightfield, spanId: i32) -> (x, y: i32) {
  for cy in 0..<chf.height {
    for cx in 0..<chf.width {
      c := &chf.cells[cx + cy * chf.width]
      cIndex, cCount := unpack_compact_cell(c.index)
      if spanId >= i32(cIndex) && spanId < i32(cIndex + u32(cCount)) {
        return cx, cy
      }
    }
  }
  return -1, -1
}

merge_small_regions :: proc(chf: ^CompactHeightfield, minRegionArea, mergeRegionArea: i32) {
  maxRegionId: u16 = 0
  for i in 0..<chf.span_count {
    if chf.spans[i].reg > maxRegionId {
      maxRegionId = chf.spans[i].reg
    }
  }

  if maxRegionId == 0 {
    log.warn("No regions found, skipping region processing")
    return
  }

  regions := make([]Region, maxRegionId + 1)
  defer {
    for &region in regions {
      delete(region.connections)
      delete(region.floors)
    }
    delete(regions)
  }

  for i in 0..=maxRegionId {
    regions[i].id = u16(i)
  }

  for i in 0..<chf.span_count {
    regId := chf.spans[i].reg
    if regId == 0 || regId > maxRegionId do continue

    regions[regId].area += 1

    x, y := get_cell_coords(chf, i32(i))
    if x == -1 || y == -1 do continue

    s := &chf.spans[i]

    for dir in 0..<4 {
      if get_con(s, dir) == NOT_CONNECTED do continue

      nx := x + get_dir_offset_x(dir)
      ny := y + get_dir_offset_y(dir)

      if nx < 0 || ny < 0 || nx >= chf.width || ny >= chf.height do continue

      ncIndex, _ := unpack_compact_cell(chf.cells[nx + ny * chf.width].index)
      ni := i32(ncIndex) + i32(get_con(s, dir))
      nr := chf.spans[ni].reg

      if nr != 0 && nr != regId {
        add_unique_connection(&regions[regId], nr)
      }
    }
  }

  merged_count := 0
  for i in 1..=maxRegionId {
    region := &regions[i]
    if region.area <= mergeRegionArea {
      mergeRegion := find_merge_target(regions, region)
      if mergeRegion != 0 {
        log.debugf("Merging region %d (area %d) into region %d", i, region.area, mergeRegion)
        remap_region(chf, u16(i), mergeRegion)
        merged_count += 1
      }
    }
  }
  
  log.infof("merge_small_regions: Merged %d regions out of %d", merged_count, maxRegionId)
}

add_unique_connection :: proc(region: ^Region, target: u16) {
  for conn in region.connections {
    if conn == target do return
  }
  append(&region.connections, target)
}

find_merge_target :: proc(regions: []Region, region: ^Region) -> u16 {
  bestTarget: u16 = 0
  bestArea: i32 = 0

  for target in region.connections {
    if target == 0 || int(target) >= len(regions) do continue

    targetRegion := &regions[target]
    if targetRegion.area > bestArea {
      bestArea = targetRegion.area
      bestTarget = target
    }
  }

  return bestTarget
}

remap_region :: proc(chf: ^CompactHeightfield, from, to: u16) {
  for i in 0..<chf.span_count {
    if chf.spans[i].reg == from {
      chf.spans[i].reg = to
    }
  }
}