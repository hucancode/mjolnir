package recast

import "core:log"
import "core:slice"

@(private = "file")
Heightfield_Layer :: struct {
  bmin:    [3]f32,
  bmax:    [3]f32,
  cs:      f32,
  ch:      f32,
  width:   i32,
  height:  i32,
  minx:    i32,
  maxx:    i32,
  miny:    i32,
  maxy:    i32,
  hmin:    i32,
  hmax:    i32,
  heights: []u8,
  areas:   []u8,
  cons:    []u8,
}

@(private = "file")
RC_MAX_LAYER_ID :: 255
@(private = "file")
RC_NULL_LAYER_ID :: 255
@(private = "file")
RC_MAX_LAYERS_DEF :: 63 // Must be ≤ 255
@(private = "file")
RC_MAX_NEIS_DEF :: 16
@(private = "file")
MAX_STACK :: 64
@(private = "file")
RC_NULL_LAYER :: u8(0xff) // Unassigned layer marker

@(private = "file")
Heightfield_Layer_Region :: struct {
  overlapping_layers: [dynamic]u8,
  neighbors:          [dynamic]u8,
  height_bounds:      [2]u16,
  layer_id:           u8,
  is_base:            bool,
}

@(private = "file")
Layer_Sweep_Span :: struct {
  sample_count: u16,
  region_id:    u8,
  neighbor_id:  u8,
}

@(private = "file")
add_unique :: proc(a: ^[dynamic]u8, v: u8) -> bool {
  if slice.contains(a[:], v) do return true
  append(a, v)
  return true
}

@(private = "file")
add_unique_capped :: proc(a: ^[dynamic]u8, v: u8, max_size: int) -> bool {
  if slice.contains(a[:], v) do return true
  if len(a) >= max_size do return false
  append(a, v)
  return true
}

@(private = "file")
ranges_overlap :: proc(a_bounds, b_bounds: [2]u16) -> bool {
  return !(a_bounds.x > b_bounds.y || a_bounds.y < b_bounds.x)
}

@(private = "file")
expand_bounds :: proc(bounds: ^[2]u16, value: u16) {
  bounds.x = min(bounds.x, value)
  bounds.y = max(bounds.y, value)
}

@(private = "file")
bounds_size :: proc(bounds: [2]u16) -> u16 {
  return bounds.y - bounds.x
}

@(private)
destroy_heightfield_layer_set :: proc(lset: [dynamic]Heightfield_Layer) {
  for layer in lset {
    delete(layer.heights)
    delete(layer.areas)
    delete(layer.cons)
  }
  delete(lset)
}

@(private)
build_heightfield_layers :: proc(
  chf: ^Compact_Heightfield,
  border_size: i32,
  walkable_height: i32,
) -> (
  result: [dynamic]Heightfield_Layer,
  success: bool,
) {
  dimensions := [2]i32{chf.width, chf.height}
  span_count := i32(len(chf.spans))
  log.infof("%v cells, %d spans", dimensions, span_count)
  src_reg := make([]u8, span_count)
  defer delete(src_reg)
  if !partition_monotone_regions(chf, border_size, src_reg) {
    log.warn("Could not partition monotone regions (likely >255 regions)")
    return {}, false
  }
  nregs := 0
  for reg in src_reg {
    if reg != RC_NULL_LAYER {
      nregs = max(nregs, int(reg) + 1)
    }
  }
  if nregs == 0 {
    log.warn("No regions found")
    return {}, true
  }
  log.infof("%d regions", nregs)
  regions := make([]Heightfield_Layer_Region, nregs)
  defer {
    for &reg in regions {
      delete(reg.overlapping_layers)
      delete(reg.neighbors)
    }
    delete(regions)
  }
  if !analyze_regions(chf, src_reg, regions) {
    log.error("Could not analyze regions")
    return {}, false
  }
  nlayers := assign_layers_dfs(regions)
  log.infof("%d layers", nlayers)
  nlayers = merge_layers(regions, walkable_height)
  log.infof("%d layers after merging", nlayers)
  nlayers = compact_layer_ids(regions)
  log.infof("%d layers after compaction", nlayers)
  lset := make([dynamic]Heightfield_Layer, 0, nlayers)
  for layer_id in 0 ..< nlayers {
    if !build_single_layer(
      chf,
      src_reg,
      regions,
      u8(layer_id),
      border_size,
      &lset,
    ) {
      log.warnf("Failed to build layer %d", layer_id)
    }
  }
  log.infof("Built %d layers", len(lset))
  return lset, true
}

@(private = "file")
partition_monotone_regions :: proc(
  chf: ^Compact_Heightfield,
  border_size: i32,
  src_reg: []u8,
) -> bool {
  w := chf.width
  h := chf.height
  slice.fill(src_reg, 0xff)
  sweeps: [dynamic]Layer_Sweep_Span
  defer delete(sweeps)
  prev_count: [256]i32
  reg_id: u8 = 0
  for y in border_size ..< (h - border_size) {
    slice.fill(prev_count[:reg_id], 0)
    sweep_id: u8 = 0
    clear(&sweeps)
    for x in border_size ..< (w - border_size) {
      c := &chf.cells[x + y * w]
      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(chf.spans)) || i >= u32(len(chf.areas)) {
          continue
        }
        if chf.areas[i] == RC_NULL_AREA {
          continue
        }
        sid: u8 = 0xff
        s := &chf.spans[i]
        if get_con(s, 0) != RC_NOT_CONNECTED {
          ax := x + get_dir_offset_x(0)
          ay := y + get_dir_offset_y(0)
          ai := chf.cells[ax + ay * w].index + u32(get_con(s, 0))
          if ai < u32(len(chf.areas)) &&
             ai < u32(len(src_reg)) &&
             chf.areas[ai] != RC_NULL_AREA &&
             src_reg[ai] != 0xff {
            sid = src_reg[ai]
          }
        }
        if sid == 0xff {
          sid = sweep_id
          sweep_id += 1
          for len(sweeps) <= int(sid) {
            append(
              &sweeps,
              Layer_Sweep_Span {
                sample_count = 0,
                region_id    = 0,
                neighbor_id  = 0xff,
              },
            )
          }
          sweeps[sid].neighbor_id = 0xff
          sweeps[sid].sample_count = 0
        }
        if get_con(s, 3) != RC_NOT_CONNECTED {
          ax := x + get_dir_offset_x(3)
          ay := y + get_dir_offset_y(3)
          ai := chf.cells[ax + ay * w].index + u32(get_con(s, 3))
          if ai < u32(len(src_reg)) {
            nr := src_reg[ai]
            if nr != 0xff {
              sweep := &sweeps[sid]
              if sweep.sample_count == 0 {
                sweep.neighbor_id = nr
              }
              if sweep.neighbor_id == nr {
                sweep.sample_count += 1
                prev_count[nr] += 1
              } else {
                sweep.neighbor_id = 0xff
              }
            }
          }
        }
        src_reg[i] = sid
      }
    }
    for i in 0 ..< int(sweep_id) {
      sweep := &sweeps[i]
      if sweep.neighbor_id != 0xff &&
         prev_count[sweep.neighbor_id] == i32(sweep.sample_count) {
        sweep.region_id = sweep.neighbor_id
      } else {
        if reg_id == 255 {
          log.warn(
            "Region ID overflow (>255 regions not supported in layer system)",
          )
          return false
        }
        sweep.region_id = reg_id
        reg_id += 1
      }
    }
    for x in border_size ..< (w - border_size) {
      c := &chf.cells[x + y * w]
      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(src_reg)) {
          continue
        }
        if src_reg[i] != 0xff {
          src_reg[i] = sweeps[src_reg[i]].region_id
        }
      }
    }
  }
  return true
}

@(private = "file")
analyze_regions :: proc(
  chf: ^Compact_Heightfield,
  src_reg: []u8,
  regions: []Heightfield_Layer_Region,
) -> bool {
  w := chf.width
  h := chf.height
  for &reg in regions {
    reg.height_bounds = {0xffff, 0}
    reg.layer_id = RC_NULL_LAYER
    reg.is_base = false
  }
  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]
      local_regions: [dynamic]u8
      defer delete(local_regions)
      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(chf.spans)) ||
           i >= u32(len(chf.areas)) ||
           i >= u32(len(src_reg)) {
          continue
        }
        if chf.areas[i] == RC_NULL_AREA {
          continue
        }
        ri := src_reg[i]
        if ri == RC_NULL_LAYER || int(ri) >= len(regions) {
          continue
        }
        s := &chf.spans[i]
        reg := &regions[ri]
        expand_bounds(&reg.height_bounds, s.y)
        expand_bounds(&reg.height_bounds, s.y)
        add_unique(&local_regions, ri)
        for dir in 0 ..< 4 {
          if get_con(s, dir) != RC_NOT_CONNECTED {
            ax := x + get_dir_offset_x(dir)
            ay := y + get_dir_offset_y(dir)
            if ax >= 0 && ax < w && ay >= 0 && ay < h {
              ai := chf.cells[ax + ay * w].index + u32(get_con(s, dir))
              if ai < u32(len(src_reg)) {
                rai := src_reg[ai]
                if rai != RC_NULL_LAYER &&
                   rai != ri &&
                   int(rai) < len(regions) {
                  add_unique(&reg.neighbors, rai)
                }
              }
            }
          }
        }
      }
      for i in 0 ..< len(local_regions) {
        for j in i + 1 ..< len(local_regions) {
          ri := local_regions[i]
          rj := local_regions[j]
          if int(ri) < len(regions) && int(rj) < len(regions) {
            add_unique(&regions[ri].overlapping_layers, rj)
            add_unique(&regions[rj].overlapping_layers, ri)
          }
        }
      }
    }
  }
  return true
}

@(private = "file")
assign_layers_dfs :: proc(regions: []Heightfield_Layer_Region) -> int {
  stack: [dynamic]int
  defer delete(stack)
  layer_id: u8 = 0
  for i in 0 ..< len(regions) {
    root := &regions[i]
    if root.layer_id != RC_NULL_LAYER {
      continue
    }
    root.layer_id = layer_id
    root.is_base = true
    clear(&stack)
    append(&stack, i)
    for len(stack) > 0 {
      reg_idx := pop(&stack)
      reg := &regions[reg_idx]
      for nei_id in reg.neighbors {
        if int(nei_id) >= len(regions) {
          continue
        }
        nei := &regions[nei_id]
        if nei.layer_id != RC_NULL_LAYER {
          continue
        }
        if slice.contains(root.overlapping_layers[:], u8(nei_id)) {
          continue
        }
        ymin := min(root.height_bounds.x, nei.height_bounds.x)
        ymax := max(root.height_bounds.y, nei.height_bounds.y)
        if ymax - ymin >= 255 {
          continue
        }
        nei.layer_id = layer_id
        append(&stack, int(nei_id))
        for overlap_id in nei.overlapping_layers {
          add_unique(&root.overlapping_layers, overlap_id)
        }
        root.height_bounds.x = ymin
        root.height_bounds.y = ymax
      }
    }
    layer_id += 1
    if layer_id == RC_NULL_LAYER {
      log.warn("Layer ID overflow (>255 layers not supported)")
      break
    }
  }
  return int(layer_id)
}

@(private = "file")
merge_layers :: proc(
  regions: []Heightfield_Layer_Region,
  walkable_height: i32,
) -> int {
  merge_height := u16(walkable_height * 4)
  max_iterations := len(regions) * 2
  iteration := 0
  for iteration < max_iterations {
    merged := false
    iteration += 1
    for i in 0 ..< len(regions) {
      ri := &regions[i]
      if !ri.is_base || ri.layer_id == RC_NULL_LAYER {
        continue
      }
      for j in i + 1 ..< len(regions) {
        rj := &regions[j]
        if !rj.is_base || rj.layer_id == RC_NULL_LAYER {
          continue
        }
        if ri.layer_id == rj.layer_id {
          continue
        }
        ri_extended := [2]u16 {
          ri.height_bounds.x,
          ri.height_bounds.y + merge_height,
        }
        rj_extended := [2]u16 {
          rj.height_bounds.x,
          rj.height_bounds.y + merge_height,
        }
        if !ranges_overlap(ri_extended, rj_extended) {
          continue
        }
        ymin := min(ri.height_bounds.x, rj.height_bounds.x)
        ymax := max(ri.height_bounds.y, rj.height_bounds.y)
        if ymax - ymin >= 255 {
          continue
        }
        can_merge := true
        if slice.contains(ri.overlapping_layers[:], u8(j)) {
          can_merge = false
        }
        if can_merge {
          for k in 0 ..< len(regions) {
            if regions[k].layer_id == ri.layer_id {
              for overlap_id in regions[k].overlapping_layers {
                if int(overlap_id) < len(regions) &&
                   regions[overlap_id].layer_id == rj.layer_id {
                  can_merge = false
                  break
                }
              }
              if !can_merge do break
            }
          }
        }
        if !can_merge {
          continue
        }
        old_id := rj.layer_id
        new_id := ri.layer_id
        for &reg in regions {
          if reg.layer_id == old_id {
            reg.layer_id = new_id
            reg.is_base = false
          }
        }
        for overlap_id in rj.overlapping_layers {
          add_unique(&ri.overlapping_layers, overlap_id)
        }
        ri.height_bounds.x = ymin
        ri.height_bounds.y = ymax
        merged = true
        break
      }
      if merged {
        break
      }
    }
    if !merged {
      break
    }
  }
  if iteration >= max_iterations {
    log.warnf(
      "Layer merging reached maximum iterations (%d), stopping to prevent infinite loop",
      max_iterations,
    )
  }
  layer_count := 0
  for reg in regions {
    if reg.is_base && reg.layer_id != RC_NULL_LAYER {
      layer_count = max(layer_count, int(reg.layer_id) + 1)
    }
  }
  return layer_count
}

@(private = "file")
compact_layer_ids :: proc(regions: []Heightfield_Layer_Region) -> int {
  used_layers := make([dynamic]bool, 256)
  defer delete(used_layers)
  slice.fill(used_layers[:], false)
  for reg in regions {
    if reg.layer_id != RC_NULL_LAYER {
      used_layers[reg.layer_id] = true
    }
  }
  remap := make([]u8, 256)
  defer delete(remap)
  layer_id: u8 = 0
  for i in 0 ..< len(used_layers) {
    if used_layers[i] {
      remap[i] = layer_id
      layer_id += 1
    } else {
      remap[i] = RC_NULL_LAYER
    }
  }
  for &reg in regions {
    if reg.layer_id != RC_NULL_LAYER {
      reg.layer_id = remap[reg.layer_id]
    }
  }
  return int(layer_id)
}

@(private = "file")
build_single_layer :: proc(
  chf: ^Compact_Heightfield,
  src_reg: []u8,
  regions: []Heightfield_Layer_Region,
  layer_id: u8,
  border_size: i32,
  layers: ^[dynamic]Heightfield_Layer,
) -> bool {
  w := chf.width
  h := chf.height
  layer_width := w - border_size * 2
  layer_height := h - border_size * 2
  if layer_width <= 0 || layer_height <= 0 {
    return false
  }
  hmin := i32(0xffff)
  hmax := i32(0)
  span_count := 0
  data_minx := i32(w)
  data_maxx := i32(0)
  data_miny := i32(h)
  data_maxy := i32(0)
  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]
      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(src_reg)) {
          continue
        }
        ri := src_reg[i]
        if ri == RC_NULL_LAYER || int(ri) >= len(regions) {
          continue
        }
        if regions[ri].layer_id != layer_id {
          continue
        }
        if i >= u32(len(chf.spans)) {
          continue
        }
        s := &chf.spans[i]
        data_minx = min(data_minx, i32(x))
        data_maxx = max(data_maxx, i32(x))
        data_miny = min(data_miny, i32(y))
        data_maxy = max(data_maxy, i32(y))
        hmin = min(hmin, i32(s.y))
        hmax = max(hmax, i32(s.y) + i32(s.h))
        span_count += 1
      }
    }
  }
  if span_count == 0 {
    return false
  }
  layer_minx := border_size
  layer_miny := border_size
  layer_bmin := chf.bmin
  layer_bmax := chf.bmax
  layer_bmin.x += f32(border_size) * chf.cs
  layer_bmin.z += f32(border_size) * chf.cs
  layer_bmax.x -= f32(border_size) * chf.cs
  layer_bmax.z -= f32(border_size) * chf.cs
  layer_bmin.y = chf.bmin.y + f32(hmin) * chf.ch
  layer_bmax.y = chf.bmin.y + f32(hmax) * chf.ch
  layer := Heightfield_Layer {
    bmin    = layer_bmin,
    bmax    = layer_bmax,
    cs      = chf.cs,
    ch      = chf.ch,
    width   = layer_width,
    height  = layer_height,
    minx    = data_minx,
    maxx    = data_maxx,
    miny    = data_miny,
    maxy    = data_maxy,
    hmin    = hmin,
    hmax    = hmax,
    heights = make([]u8, int(layer_width * layer_height)),
    areas   = make([]u8, int(layer_width * layer_height)),
    cons    = make([]u8, int(layer_width * layer_height)),
  }
  slice.fill(layer.heights, 0xff)
  slice.fill(layer.areas, RC_NULL_AREA)
  slice.fill(layer.cons, 0)
  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]
      for i in c.index ..< c.index + u32(c.count) {
        if i >= u32(len(src_reg)) {
          continue
        }
        ri := src_reg[i]
        if ri == RC_NULL_LAYER || int(ri) >= len(regions) {
          continue
        }
        if regions[ri].layer_id != layer_id {
          continue
        }
        if i >= u32(len(chf.spans)) || i >= u32(len(chf.areas)) {
          continue
        }
        s := &chf.spans[i]
        lx := x - border_size
        ly := y - border_size
        if lx < 0 || lx >= layer_width || ly < 0 || ly >= layer_height {
          continue
        }
        lidx := lx + ly * layer_width
        if lidx < 0 || lidx >= i32(len(layer.heights)) {
          continue
        }
        relative_height := i32(s.y) - hmin
        layer.heights[lidx] = u8(clamp(int(relative_height), 0, 255))
        layer.areas[lidx] = chf.areas[i]
        cons: u8 = 0
        for dir in 0 ..< 4 {
          if get_con(s, dir) != RC_NOT_CONNECTED {
            ax := x + get_dir_offset_x(dir)
            ay := y + get_dir_offset_y(dir)
            if ax >= 0 && ax < w && ay >= 0 && ay < h {
              ac := &chf.cells[ax + ay * w]
              ai := ac.index + u32(get_con(s, dir))
              if ai < u32(len(src_reg)) {
                rai := src_reg[ai]
                if rai != RC_NULL_LAYER && int(rai) < len(regions) {
                  if regions[rai].layer_id == layer_id {
                    alx := ax - border_size
                    aly := ay - border_size
                    if alx >= 0 &&
                       alx < layer_width &&
                       aly >= 0 &&
                       aly < layer_height {
                      cons |= u8(1 << u8(dir))
                    }
                  } else {
                    alx := ax - border_size
                    aly := ay - border_size
                    if alx >= 0 &&
                       alx < layer_width &&
                       aly >= 0 &&
                       aly < layer_height {
                      cons |= u8(1 << u8(dir))
                    }
                  }
                }
              }
            }
          }
        }
        layer.cons[lidx] = cons
      }
    }
  }
  append(layers, layer)
  return true
}

@(private = "file")
get_layer_height :: proc(layer: ^Heightfield_Layer, x, y: i32) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return 0xff
  }
  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.heights)) {
    return 0xff
  }
  return layer.heights[idx]
}

@(private = "file")
get_layer_area :: proc(layer: ^Heightfield_Layer, x, y: i32) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return RC_NULL_AREA
  }
  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.areas)) {
    return RC_NULL_AREA
  }
  return layer.areas[idx]
}

@(private = "file")
get_layer_connection :: proc(layer: ^Heightfield_Layer, x, y: i32) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return 0
  }
  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.cons)) {
    return 0
  }
  return layer.cons[idx]
}

@(private = "file")
validate_layer_set :: proc(lset: [dynamic]Heightfield_Layer) -> bool {
  if len(lset) == 0 do return false
  layer_ok :: proc(layer: Heightfield_Layer) -> bool {
    if layer.width <= 0 || layer.height <= 0 {
      return false
    }
    expected_size := int(layer.width * layer.height)
    if len(layer.heights) != expected_size ||
       len(layer.areas) != expected_size ||
       len(layer.cons) != expected_size {
      return false
    }
    if layer.minx > layer.maxx || layer.miny > layer.maxy {
      return false
    }
    return true
  }
  return slice.all_of_proc(lset[:], layer_ok)
}
