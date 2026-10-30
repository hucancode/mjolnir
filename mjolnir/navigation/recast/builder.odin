package recast

import "../../geometry"
import "core:log"
import "core:math/linalg"
import "core:slice"

@(private)
Contour :: struct {
  verts:  [][4]i32,
  rverts: [][4]i32,
  reg:    u16,
  area:   u8,
}

@(private)
Contour_Set :: struct {
  conts:       [dynamic]Contour,
  bmin:        [3]f32,
  bmax:        [3]f32,
  cs:          f32,
  ch:          f32,
  width:       i32,
  height:      i32,
  border_size: i32,
  max_error:   f32,
}

@(private = "file")
Contour_Tess_Flag :: enum {
  WALL_EDGES = 0,
  AREA_EDGES = 1,
}
@(private = "file")
Contour_Tess_Flags :: bit_set[Contour_Tess_Flag;u32]

@(private = "file")
Potential_Diagonal :: struct {
  vert: i32,
  dist: i32,
}

// build_navmesh runs the full Recast pipeline on triangle input and returns the polygon mesh and its detail mesh.
build_navmesh :: proc(
  vertices: [][3]f32,
  indices: []i32,
  areas: []u8,
  cfg: Config,
) -> (
  pmesh: ^Poly_Mesh,
  dmesh: ^Poly_Mesh_Detail,
  ok: bool,
) {
  if len(vertices) == 0 || len(indices) == 0 || cfg.cs <= 0 || cfg.ch <= 0 {
    return
  }
  config := cfg
  if config.bmin == {} && config.bmax == {} {
    config.bmin, config.bmax = calc_bounds(vertices)
  }
  config.width, config.height = calc_grid_size(
    config.bmin,
    config.bmax,
    config.cs,
  )
  if config.width <= 0 || config.height <= 0 {
    return
  }
  hf := create_heightfield(
    config.width,
    config.height,
    config.bmin,
    config.bmax,
    config.cs,
    config.ch,
  )
  defer destroy_heightfield(hf)
  rasterize_triangles(
    vertices,
    indices,
    areas,
    hf,
    config.walkable_climb,
  ) or_return
  filter_low_hanging_walkable_obstacles(int(config.walkable_climb), hf)
  filter_ledge_spans(
    int(config.walkable_height),
    int(config.walkable_climb),
    hf,
  )
  filter_walkable_low_height_spans(int(config.walkable_height), hf)
  chf := create_compact_heightfield(
    config.walkable_height,
    config.walkable_climb,
    hf,
  )
  if chf == nil do return
  defer destroy_compact_heightfield(chf)
  erode_walkable_area(config.walkable_radius, chf) or_return
  build_distance_field(chf) or_return
  build_regions(
    chf,
    0,
    config.min_region_area,
    config.merge_region_area,
  ) or_return
  cset := create_contour_set(
    chf,
    config.max_simplification_error,
    config.max_edge_len,
  )
  if cset == nil do return
  defer destroy_contour_set(cset)
  pmesh = create_poly_mesh(cset, config.max_verts_per_poly)
  if pmesh == nil {
    return
  }
  dmesh = create_poly_mesh_detail(
    pmesh,
    chf,
    config.detail_sample_dist,
    config.detail_sample_max_error,
  )
  if dmesh == nil {
    destroy_poly_mesh(pmesh)
    return
  }
  return pmesh, dmesh, true
}

@(private = "file")
Contour_Hole :: struct {
  contour:    ^Contour,
  minx, minz: i32,
  leftmost:   i32,
}

@(private = "file")
Contour_Region :: struct {
  outline: ^Contour,
  holes:   []Contour_Hole,
  nholes:  i32,
}

@(private)
build_compact_heightfield :: proc(
  walkable_height, walkable_climb: i32,
  hf: ^Heightfield,
  chf: ^Compact_Heightfield,
) -> bool {
  w := hf.width
  h := hf.height
  span_count := 0
  chf.width = w
  chf.height = h
  chf.walkable_height = walkable_height
  chf.walkable_climb = walkable_climb
  chf.max_distance = 0
  chf.max_regions = 0
  chf.bmin = hf.bmin
  chf.bmax = hf.bmax
  chf.bmax.y += f32(walkable_height) * hf.ch
  chf.cs = hf.cs
  chf.ch = hf.ch
  // Note: C++ doesn't set border_size in rcBuildCompactHeightfield
  chf.border_size = 0
  chf.cells = make([]Compact_Cell, w * h)
  max_spans := 0
  for y in 0 ..< h {
    for x in 0 ..< w {
      s := hf.spans[x + y * w]
      if s == nil do continue
      span_num := 0
      for s != nil {
        if s.area != RC_NULL_AREA {
          span_count += 1
          span_num += 1
        }
        s = s.next
      }
      max_spans = max(max_spans, span_num)
    }
  }
  if span_count == 0 do return true
  chf.spans = make([]Compact_Span, span_count)
  chf.areas = make([]u8, span_count)
  slice.fill(chf.areas, RC_NULL_AREA)
  idx := 0
  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]
      c.index = u32(idx)
      c.count = 0
      for s := hf.spans[x + y * w]; s != nil; s = s.next {
        if s.area != RC_NULL_AREA {
          bottom := i32(s.smax)
          next := s.next
          top := next != nil ? i32(next.smin) : RC_SPAN_MAX_HEIGHT
          cs := &chf.spans[idx]
          cs.y = u16(clamp(bottom, 0, 0xffff))
          cs.h = u8(clamp(top - bottom, 0, 0xff))
          chf.areas[idx] = u8(s.area)
          idx += 1
          c.count = c.count + 1
        }
      }
    }
  }
  max_layers := max_spans
  too_high_neighbor := 0
  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]
      for i in c.index ..< c.index + u32(c.count) {
        s := &chf.spans[i]
        for dir in 0 ..< 4 {
          set_con(s, dir, RC_NOT_CONNECTED)
          nx := int(x) + int(get_dir_offset_x(dir))
          ny := int(y) + int(get_dir_offset_y(dir))
          if nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h) do continue
          nc := &chf.cells[nx + ny * int(w)]
          for k in nc.index ..< nc.index + u32(nc.count) {
            ns := &chf.spans[k]
            bot := max(int(s.y), int(ns.y))
            top := min(int(s.y) + int(s.h), int(ns.y) + int(ns.h))
            if (top - bot) >= int(walkable_height) &&
               abs(int(ns.y) - int(s.y)) <= int(walkable_climb) {
              lidx := int(k - nc.index)
              if lidx < 0 || lidx > max_layers {
                too_high_neighbor = max(too_high_neighbor, lidx)
                continue
              }
              set_con(s, dir, lidx)
              break
            }
          }
        }
      }
    }
  }
  if too_high_neighbor > max_layers {
    return false
  }
  return true
}

@(private = "file")
find_leftmost_vertex :: proc(
  contour: ^Contour,
) -> (
  minx, minz, leftmost: i32,
) {
  minx = contour.verts[0].x
  minz = contour.verts[0].z
  leftmost = 0
  for i in 1 ..< len(contour.verts) {
    x := contour.verts[i].x
    z := contour.verts[i].z
    if x < minx || (x == minx && z < minz) {
      minx = x
      minz = z
      leftmost = i32(i)
    }
  }
  return minx, minz, leftmost
}

@(private = "file")
in_cone_hole :: proc(i: i32, verts: [][4]i32, pj: [4]i32) -> bool {
  n := i32(len(verts))
  pi := verts[i]
  pi1 := verts[(i + 1) % n]
  pin1 := verts[(i + n - 1) % n]
  return in_cone(pin1.xz, pi.xz, pi1.xz, pj.xz)
}

@(private = "file")
intersect_segment_contour :: proc(
  d0, d1: [4]i32,
  i: i32,
  verts: [][4]i32,
) -> bool {
  n := len(verts)
  for k in 0 ..< n {
    k1 := (k + 1) % n
    if i32(k) == i || i32(k1) == i {
      continue
    }
    p0 := verts[k]
    p1 := verts[k1]
    if d0.xz == p0.xz || d1.xz == p0.xz || d0.xz == p1.xz || d1.xz == p1.xz {
      continue
    }
    if intersect(d0.xz, d1.xz, p0.xz, p1.xz) {
      return true
    }
  }
  return false
}

@(private = "file")
merge_contours :: proc(ca, cb: ^Contour, ia, ib: int) -> bool {
  na := len(ca.verts)
  nb := len(cb.verts)
  verts := make([][4]i32, na + nb + 2)
  defer delete(verts)
  n := 0
  copy(verts[n:], ca.verts[ia:])
  n += na - ia
  copy(verts[n:], ca.verts[:ia + 1])
  n += ia + 1
  copy(verts[n:], cb.verts[ib:])
  n += nb - ib
  copy(verts[n:], cb.verts[:ib + 1])
  n += ib + 1
  delete(ca.verts)
  ca.verts = slice.clone(verts[:n])
  delete(cb.verts)
  cb.verts = nil
  return true
}

@(private = "file")
merge_region_holes :: proc(reg: ^Contour_Region) {
  slice.sort_by(reg.holes[:reg.nholes], proc(a, b: Contour_Hole) -> bool {
    if a.minx == b.minx {
      return a.minz < b.minz
    }
    return a.minx < b.minx
  })
  for i in 0 ..< reg.nholes {
    hole := &reg.holes[i]
    index := -1
    best_vertex := int(hole.leftmost)
    for _ in 0 ..< len(hole.contour.verts) {
      diags := make([dynamic]Potential_Diagonal, 0, len(reg.outline.verts))
      defer delete(diags)
      corner := hole.contour.verts[best_vertex]
      for j in 0 ..< len(reg.outline.verts) {
        if in_cone_hole(i32(j), reg.outline.verts, corner) {
          diff_xz := reg.outline.verts[j].xz - corner.xz
          append(
            &diags,
            Potential_Diagonal{vert = i32(j), dist = linalg.length2(diff_xz)},
          )
        }
      }
      slice.sort_by(diags[:], proc(a, b: Potential_Diagonal) -> bool {
        return a.dist < b.dist
      })
      for j in 0 ..< len(diags) {
        pt := reg.outline.verts[diags[j].vert]
        intersects := intersect_segment_contour(
          pt,
          corner,
          diags[j].vert,
          reg.outline.verts,
        )
        for k := i; k < reg.nholes && !intersects; k += 1 {
          intersects =
            intersects ||
            intersect_segment_contour(
              pt,
              corner,
              -1,
              reg.holes[k].contour.verts,
            )
        }
        if !intersects {
          index = int(diags[j].vert)
          break
        }
      }
      if index != -1 {
        break
      }
      best_vertex = (best_vertex + 1) % len(hole.contour.verts)
    }
    if index == -1 {
      log.warnf("Failed to find merge point for hole %d", i)
      continue
    }
    if !merge_contours(reg.outline, hole.contour, index, best_vertex) {
      log.warnf("Failed to merge hole %d", i)
      continue
    }
  }
}

@(private = "file")
build_contours :: proc(
  chf: ^Compact_Heightfield,
  max_error: f32,
  max_edge_len: i32,
  cset: ^Contour_Set,
  build_flags: Contour_Tess_Flags = {.WALL_EDGES},
) -> bool {
  w := chf.width
  h := chf.height
  border_size := chf.border_size
  cset.bmin = chf.bmin
  cset.bmax = chf.bmax
  if border_size > 0 {
    pad := f32(border_size) * chf.cs
    cset.bmin += [3]f32{pad, 0, pad}
    cset.bmax -= [3]f32{pad, 0, pad}
  }
  cset.cs = chf.cs
  cset.ch = chf.ch
  cset.width = chf.width - border_size * 2
  cset.height = chf.height - border_size * 2
  cset.border_size = border_size
  cset.max_error = max_error
  flags := make([]u8, len(chf.spans))
  defer delete(flags)
  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]
      span_idx := c.index
      span_count := c.count
      for i in span_idx ..< span_idx + u32(span_count) {
        s := &chf.spans[i]
        res: u8 = 0
        if s.reg == 0 || (s.reg & RC_BORDER_REG) != 0 {
          flags[i] = 0
          continue
        }
        for dir in 0 ..< 4 {
          r: u16 = 0
          if get_con(s, dir) != RC_NOT_CONNECTED {
            ax := x + get_dir_offset_x(dir)
            ay := y + get_dir_offset_y(dir)
            if ax >= 0 && ay >= 0 && ax < w && ay < h {
              ai := chf.cells[ax + ay * w].index + u32(get_con(s, dir))
              if ai < u32(len(chf.spans)) {
                r = chf.spans[ai].reg
              }
            }
          }
          if r == s.reg {
            res |= (1 << u8(dir))
          }
        }
        flags[i] = res ~ 0xf
      }
    }
  }
  verts: [dynamic][4]i32
  defer delete(verts)
  simplified: [dynamic][4]i32
  defer delete(simplified)
  contours_created := 0
  total_verts_processed := 0
  boundary_spans_found := 0
  for y in 0 ..< h {
    for x in 0 ..< w {
      c := &chf.cells[x + y * w]
      span_idx := c.index
      span_count := c.count
      spans_in_cell := 0
      for i in span_idx ..< span_idx + u32(span_count) {
        spans_in_cell += 1
        if spans_in_cell > 100 {
          log.warnf(
            "Cell at (%d, %d) has excessive spans (%d), stopping processing",
            x,
            y,
            spans_in_cell,
          )
          break
        }
        if flags[i] == 0 || flags[i] == 0xf {
          flags[i] = 0
          continue
        }
        region_id := chf.spans[i].reg
        if region_id == 0 || (region_id & RC_BORDER_REG) != 0 {
          continue
        }
        area_id := chf.areas[i]
        boundary_spans_found += 1
        clear(&verts)
        clear(&simplified)
        walk_contour_boundary(i32(x), i32(y), i32(i), chf, flags[:], &verts)
        if len(verts) >= 3 {
          if max_error > 0.01 {
            simplify_contour(
              verts[:],
              &simplified,
              max_error,
              chf.cs,
              max_edge_len,
              build_flags,
            )
            remove_degenerate_contour_segments(&simplified)
          } else {
            for v in verts {
              append(&simplified, v)
            }
            remove_degenerate_contour_segments(&simplified)
          }
          if len(simplified) >= 3 {
            append(&cset.conts, Contour{})
            cont := slice.last_ptr(cset.conts[:])
            cont.area = area_id
            cont.reg = region_id
            cont.verts = make([][4]i32, len(simplified))
            copy(cont.verts, simplified[:])
            if border_size > 0 {
              for &v in cont.verts {
                v.x -= border_size
                v.z -= border_size
              }
            }
            cont.rverts = make([][4]i32, len(verts))
            copy(cont.rverts, verts[:])
            if border_size > 0 {
              for &v in cont.rverts {
                v.x -= border_size
                v.z -= border_size
              }
            }
            contours_created += 1
            total_verts_processed += len(verts)
          }}
      }
    }
  }
  if len(cset.conts) > 0 {
    winding := make([]i8, len(cset.conts))
    defer delete(winding)
    for i in 0 ..< len(cset.conts) {
      cont := &cset.conts[i]
      area := calculate_contour_area(cont.verts)
      winding[i] = area < 0 ? -1 : 1
    }
    nholes := slice.count_proc(winding, proc(w: i8) -> bool {return w < 0})
    if nholes > 0 {
      nregions := chf.max_regions + 1
      regions := make([]Contour_Region, nregions)
      defer delete(regions)
      holes := make([]Contour_Hole, len(cset.conts))
      defer delete(holes)
      for i in 0 ..< len(cset.conts) {
        cont := &cset.conts[i]
        if winding[i] > 0 {
          if regions[cont.reg].outline != nil {
            log.errorf("Multiple outlines for region %d", cont.reg)
          }
          regions[cont.reg].outline = cont
        } else {
          regions[cont.reg].nholes += 1
        }
      }
      hole_index := 0
      for i in 0 ..< nregions {
        if regions[i].nholes > 0 {
          regions[i].holes =
          holes[hole_index:hole_index + int(regions[i].nholes)]
          hole_index += int(regions[i].nholes)
          regions[i].nholes = 0
        }
      }
      for i in 0 ..< len(cset.conts) {
        cont := &cset.conts[i]
        reg := &regions[cont.reg]
        if winding[i] < 0 {
          minx, minz, leftmost := find_leftmost_vertex(cont)
          hole := &reg.holes[reg.nholes]
          hole.contour = cont
          hole.minx = minx
          hole.minz = minz
          hole.leftmost = leftmost
          reg.nholes += 1
        }
      }
      for i in 0 ..< nregions {
        reg := &regions[i]
        if reg.nholes == 0 do continue
        if reg.outline != nil {
          merge_region_holes(reg)
        } else {
          // self-overlapping contour from too aggressive simplification
          log.errorf(
            "Bad outline for region %d, contour simplification is likely too aggressive.",
            i,
          )
        }
      }
    }
  }
  return true
}

@(private = "file")
walk_contour_boundary :: proc(
  x, y, i: i32,
  chf: ^Compact_Heightfield,
  flags: []u8,
  points: ^[dynamic][4]i32,
) -> bool {
  if i < 0 || i >= i32(len(flags)) {
    log.errorf(
      "Invalid span index %d for boundary walk (flags array length: %d)",
      i,
      len(flags),
    )
    return false
  }
  if x < 0 || x >= chf.width || y < 0 || y >= chf.height {
    log.errorf(
      "Invalid coordinates (%d, %d) for boundary walk (heightfield size: %dx%d)",
      x,
      y,
      chf.width,
      chf.height,
    )
    return false
  }
  dir: u8 = 0
  for (flags[i] & (1 << dir)) == 0 {
    dir += 1
    if dir >= 4 {
      return false
    }
  }
  start_dir := dir
  start_i := i
  area := chf.areas[i]
  curr_x, curr_y, curr_i := x, y, i
  iter: i32 = 0
  for iter < 40000 {
    iter += 1
    if curr_i < 0 || curr_i >= i32(len(chf.spans)) {
      log.errorf(
        "walk_contour_boundary: curr_i %d out of bounds [0, %d)",
        curr_i,
        len(chf.spans),
      )
      return false
    }
    if (flags[curr_i] & (1 << dir)) != 0 {
      is_area_border := false
      px := curr_x
      py, is_border_vertex := get_corner_height_for_contour(
        curr_x,
        curr_y,
        curr_i,
        i32(dir),
        chf,
      )
      pz := curr_y
      switch dir {
      case 0:
        pz += 1
      case 1:
        px += 1;pz += 1
      case 2:
        px += 1
      case 3:
      }
      r: i32 = 0
      s := &chf.spans[curr_i]
      if get_con(s, int(dir)) != RC_NOT_CONNECTED {
        ax := curr_x + i32(get_dir_offset_x(int(dir)))
        ay := curr_y + i32(get_dir_offset_y(int(dir)))
        if ax >= 0 && ax < chf.width && ay >= 0 && ay < chf.height {
          ai :=
            i32(chf.cells[ax + ay * chf.width].index) +
            i32(get_con(s, int(dir)))
          if ai >= 0 && ai < i32(len(chf.spans)) {
            r = i32(chf.spans[ai].reg)
            if ai < i32(len(chf.areas)) && area != chf.areas[ai] {
              is_area_border = true
            }
          }
        }
      }
      if is_border_vertex {
        r |= RC_BORDER_VERTEX
      }
      if is_area_border {
        r |= RC_AREA_BORDER
      }
      append(points, [4]i32{px, py, pz, r})
      flags[curr_i] &= ~(1 << dir)
      dir = (dir + 1) & 0x3
    } else {
      ni := i32(-1)
      nx := curr_x + i32(get_dir_offset_x(int(dir)))
      ny := curr_y + i32(get_dir_offset_y(int(dir)))
      s := &chf.spans[curr_i]
      if get_con(s, int(dir)) != RC_NOT_CONNECTED {
        if nx >= 0 && nx < chf.width && ny >= 0 && ny < chf.height {
          nc := &chf.cells[nx + ny * chf.width]
          ni = i32(nc.index) + i32(get_con(s, int(dir)))
        }
      }
      if ni == -1 {
        return false
      }
      if ni < 0 || ni >= i32(len(chf.spans)) {
        log.errorf(
          "walk_contour_boundary: ni %d out of bounds [0, %d)",
          ni,
          len(chf.spans),
        )
        return false
      }
      curr_x = nx
      curr_y = ny
      curr_i = ni
      dir = (dir + 3) & 0x3
    }
    if start_i == curr_i && start_dir == dir {
      return true
    }
  }
  log.errorf(
    "Boundary walk exceeded maximum iterations, may indicate corrupted heightfield",
  )
  return false
}

@(private = "file")
get_corner_height_for_contour :: proc(
  x, y, i, dir: i32,
  chf: ^Compact_Heightfield,
) -> (
  ret: i32,
  is_border_vertex: bool,
) {
  if i < 0 || i >= i32(len(chf.spans)) {
    log.errorf("Invalid span index %d in get_corner_height_for_contour", i)
    return 0, false
  }
  s := &chf.spans[i]
  ch := i32(s.y)
  dirp := (dir + 1) & 0x3
  regs: [4]u32
  regs[0] = u32(s.reg) | (u32(chf.areas[i]) << 16)
  if get_con(s, int(dir)) != RC_NOT_CONNECTED {
    ax := x + i32(get_dir_offset_x(int(dir)))
    ay := y + i32(get_dir_offset_y(int(dir)))
    if ax >= 0 && ax < chf.width && ay >= 0 && ay < chf.height {
      ai :=
        i32(chf.cells[ax + ay * chf.width].index) + i32(get_con(s, int(dir)))
      if ai >= 0 && ai < i32(len(chf.spans)) {
        as := &chf.spans[ai]
        ch = max(ch, i32(as.y))
        regs[1] = u32(as.reg) | (u32(chf.areas[ai]) << 16)
        if get_con(as, int(dirp)) != RC_NOT_CONNECTED {
          ax2 := ax + i32(get_dir_offset_x(int(dirp)))
          ay2 := ay + i32(get_dir_offset_y(int(dirp)))
          if ax2 >= 0 && ax2 < chf.width && ay2 >= 0 && ay2 < chf.height {
            ai2 :=
              i32(chf.cells[ax2 + ay2 * chf.width].index) +
              i32(get_con(as, int(dirp)))
            if ai2 >= 0 && ai2 < i32(len(chf.spans)) {
              as2 := &chf.spans[ai2]
              ch = max(ch, i32(as2.y))
              regs[2] = u32(as2.reg) | (u32(chf.areas[ai2]) << 16)
            }
          }
        }
      }
    }
  }
  if get_con(s, int(dirp)) != RC_NOT_CONNECTED {
    ax := x + i32(get_dir_offset_x(int(dirp)))
    ay := y + i32(get_dir_offset_y(int(dirp)))
    if ax >= 0 && ax < chf.width && ay >= 0 && ay < chf.height {
      ai :=
        i32(chf.cells[ax + ay * chf.width].index) + i32(get_con(s, int(dirp)))
      if ai >= 0 && ai < i32(len(chf.spans)) {
        as := &chf.spans[ai]
        ch = max(ch, i32(as.y))
        regs[3] = u32(as.reg) | (u32(chf.areas[ai]) << 16)
        if get_con(as, int(dir)) != RC_NOT_CONNECTED {
          ax2 := ax + i32(get_dir_offset_x(int(dir)))
          ay2 := ay + i32(get_dir_offset_y(int(dir)))
          if ax2 >= 0 && ax2 < chf.width && ay2 >= 0 && ay2 < chf.height {
            ai2 :=
              i32(chf.cells[ax2 + ay2 * chf.width].index) +
              i32(get_con(as, int(dir)))
            if ai2 >= 0 && ai2 < i32(len(chf.spans)) {
              as2 := &chf.spans[ai2]
              ch = max(ch, i32(as2.y))
              regs[2] = u32(as2.reg) | (u32(chf.areas[ai2]) << 16)
            }
          }
        }
      }
    }
  }
  for j in 0 ..< 4 {
    a := j
    b := (j + 1) & 0x3
    c := (j + 2) & 0x3
    d := (j + 3) & 0x3
    two_same_exts :=
      (regs[a] & regs[b] & RC_BORDER_REG) != 0 && regs[a] == regs[b]
    two_ints := ((regs[c] | regs[d]) & RC_BORDER_REG) == 0
    ints_same_area := (regs[c] >> 16) == (regs[d] >> 16)
    no_zeros := regs[a] != 0 && regs[b] != 0 && regs[c] != 0 && regs[d] != 0
    if two_same_exts && two_ints && ints_same_area && no_zeros {
      return ch, true
    }
  }
  return ch, false
}

@(private = "file")
remove_degenerate_contour_segments :: proc(simplified: ^[dynamic][4]i32) {
  if len(simplified) <= 1 {
    return
  }
  write_idx := 0
  for read_idx in 0 ..< len(simplified) {
    next_idx := (read_idx + 1) % len(simplified)
    if simplified[read_idx][0] != simplified[next_idx][0] ||
       simplified[read_idx][2] != simplified[next_idx][2] {
      simplified[write_idx] = simplified[read_idx]
      write_idx += 1
    }
  }
  resize(simplified, write_idx)
}

// create_contour_set traces region outlines of a compact heightfield into simplified contours.
create_contour_set :: proc(
  chf: ^Compact_Heightfield,
  max_error: f32,
  max_edge_len: i32,
  build_flags: Contour_Tess_Flags = {.WALL_EDGES},
) -> ^Contour_Set {
  cset := new(Contour_Set)
  if !build_contours(chf, max_error, max_edge_len, cset, build_flags) {
    destroy_contour_set(cset)
    return nil
  }
  return cset
}

// destroy_contour_set frees the contours and the set.
destroy_contour_set :: proc(cset: ^Contour_Set) {
  if cset == nil do return
  for cont in cset.conts {
    delete(cont.verts)
    delete(cont.rverts)
  }
  delete(cset.conts)
  free(cset)
}

@(private)
simplify_contour :: proc(
  raw_verts: [][4]i32,
  simplified: ^[dynamic][4]i32,
  max_error: f32,
  cell_size: f32,
  max_edge_len: i32 = 12,
  build_flags: Contour_Tess_Flags = {.WALL_EDGES},
) {
  clear(simplified)
  if len(raw_verts) < 3 {
    for v in raw_verts {
      append(simplified, v)
    }
    return
  }
  if max_error <= 0.0 {
    for v in raw_verts {
      append(simplified, v)
    }
    return
  }
  n_verts := len(raw_verts)
  has_connections := false
  for i := 0; i < n_verts; i += 1 {
    if (raw_verts[i].w & RC_CONTOUR_REG_MASK) != 0 {
      has_connections = true
      break
    }
  }
  if has_connections {
    seed_count := 0
    for i := 0; i < n_verts; i += 1 {
      ii := (i + 1) % n_verts
      different_regs :=
        (raw_verts[i].w & RC_CONTOUR_REG_MASK) !=
        (raw_verts[ii].w & RC_CONTOUR_REG_MASK)
      area_borders :=
        (raw_verts[i].w & RC_AREA_BORDER) != (raw_verts[ii].w & RC_AREA_BORDER)
      if different_regs || area_borders {
        v := raw_verts[i]
        append(simplified, [4]i32{v[0], v[1], v[2], i32(i)})
        seed_count += 1
      }
    }
  }
  if len(simplified) == 0 {
    llx, llz := raw_verts[0][0], raw_verts[0][2]
    urx, urz := raw_verts[0][0], raw_verts[0][2]
    lli, uri := 0, 0
    for i := 0; i < n_verts; i += 1 {
      x := raw_verts[i].x
      z := raw_verts[i].z
      if x < llx || (x == llx && z < llz) {
        llx = x
        llz = z
        lli = i
      }
      if x > urx || (x == urx && z > urz) {
        urx = x
        urz = z
        uri = i
      }
    }
    v := raw_verts[lli]
    append(simplified, [4]i32{v[0], v[1], v[2], i32(lli)})
    if uri != lli {
      v = raw_verts[uri]
      append(simplified, [4]i32{v[0], v[1], v[2], i32(uri)})
    }
  }
  error_sq := max_error * max_error
  for i := 0; i < len(simplified); {
    ii := (i + 1) % len(simplified)
    a := simplified[i]
    ax := a[0]
    az := a[2]
    ai := a[3]
    b := simplified[ii]
    bx := b[0]
    bz := b[2]
    bi := b[3]
    max_d := f32(0)
    max_i := -1
    ci := (ai + 1) % i32(n_verts)
    if (raw_verts[ci].w & RC_CONTOUR_REG_MASK) == 0 ||
       (raw_verts[ci].w & RC_AREA_BORDER) != 0 {
      for ci != bi {
        v := raw_verts[ci]
        pt := [3]f32{f32(v[0]), 0, f32(v[2])}
        seg_start := [3]f32{f32(ax), 0, f32(az)}
        seg_end := [3]f32{f32(bx), 0, f32(bz)}
        d, _ := geometry.point_segment_distance2_2d(pt, seg_start, seg_end)
        if d > max_d {
          max_d = d
          max_i = int(ci)
        }
        ci = (ci + 1) % i32(n_verts)
      }
    }
    if max_i != -1 && max_d > error_sq {
      v := raw_verts[max_i]
      inject_at(simplified, i + 1, [4]i32{v[0], v[1], v[2], i32(max_i)})
    } else {
      i += 1
    }
  }
  if max_edge_len > 0 &&
     (Contour_Tess_Flag.WALL_EDGES in build_flags ||
         Contour_Tess_Flag.AREA_EDGES in build_flags) {
    i := 0
    for i < len(simplified) {
      ii := (i + 1) % len(simplified)
      a := simplified[i]
      b := simplified[ii]
      ab := b - a
      ci := (a.w + 1) % i32(n_verts)
      tess := false
      vertex_flags := transmute(Vertex_Flags)raw_verts[ci].w
      if Contour_Tess_Flag.WALL_EDGES in build_flags &&
         (raw_verts[ci].w & RC_CONTOUR_REG_MASK) == 0 {
        tess = true
      }
      if .AREA_EDGES in build_flags && .AREA_BORDER in vertex_flags {
        tess = true
      }
      max_i := -1
      if tess {
        edge_len_sq := linalg.length2([2]f32{f32(ab.x), f32(ab.z)})
        if edge_len_sq > f32(max_edge_len * max_edge_len) {
          n := ab.w if ab.w > 0 else ab.w + i32(n_verts)
          if n > 1 {
            if b.x > a.x || (b.x == a.x && b.z > a.z) {
              max_i = int((a.w + n / 2) % i32(n_verts))
            } else {
              max_i = int((a.w + (n + 1) / 2) % i32(n_verts))
            }
          }
        }
      }
      if max_i != -1 {
        v := raw_verts[max_i]
        inject_at(simplified, i + 1, [4]i32{v.x, v.y, v.z, i32(max_i)})
      } else {
        i += 1
      }
    }
  }
  for i in 0 ..< len(simplified) {
    ai := (simplified[i].w + 1) % i32(n_verts)
    bi := simplified[i].w
    simplified[i].w =
      (raw_verts[ai].w & (RC_CONTOUR_REG_MASK | RC_AREA_BORDER)) |
      (raw_verts[bi].w & RC_BORDER_VERTEX)
  }
}
