package bake

import "../detour"
import "../recast"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

#assert(recast.RC_MAX_VERTS_PER_POLY <= detour.DT_VERTS_PER_POLYGON)

@(private)
create_nav_mesh_data :: proc(
  params: ^Create_Nav_Mesh_Data_Params,
) -> (
  []u8,
  detour.Status,
) {
  if params == nil || params.poly_mesh == nil {
    return nil, {.Invalid_Param}
  }
  pmesh := params.poly_mesh
  dmesh := params.poly_mesh_detail
  if len(pmesh.verts) >= 0xfffe {
    return nil, {.Invalid_Param}
  }
  if pmesh.npolys >= 0xfffe {
    return nil, {.Invalid_Param}
  }
  nvp := pmesh.nvp
  cs := pmesh.cs
  ch := pmesh.ch
  off_mesh_con_class := make([]u8, params.off_mesh_con_count * 2)
  defer delete(off_mesh_con_class)
  stored_off_mesh_con_count := i32(0)
  off_mesh_con_link_count := i32(0)
  if params.off_mesh_con_count > 0 {
    classify_off_mesh_connections(pmesh, params, off_mesh_con_class)
    for i in 0 ..< params.off_mesh_con_count {
      if off_mesh_con_class[i * 2 + 0] == 0xff {
        stored_off_mesh_con_count += 1
        off_mesh_con_link_count += 1
      }
      if off_mesh_con_class[i * 2 + 1] == 0xff {
        off_mesh_con_link_count += 1
      }
    }
  }
  total_vert_count := i32(0)
  total_poly_count := i32(0)
  max_link_count := i32(0)
  total_vert_count += i32(len(pmesh.verts))
  total_poly_count += pmesh.npolys
  edge_count := i32(0)
  portal_count := i32(0)
  for i in 0 ..< pmesh.npolys {
    poly_base := i * nvp * 2
    for j in 0 ..< nvp {
      if pmesh.polys[poly_base + j] == recast.RC_MESH_NULL_IDX {
        break
      }
      edge_count += 1
      if pmesh.polys[poly_base + nvp + j] & 0x8000 != 0 {
        dir := pmesh.polys[poly_base + nvp + j] & 0xf
        if dir != 0xf {
          portal_count += 1
        }
      }
    }
  }
  max_link_count = edge_count + portal_count * 2
  total_vert_count += stored_off_mesh_con_count * 2
  total_poly_count += stored_off_mesh_con_count
  max_link_count += off_mesh_con_link_count
  detail_mesh_count := i32(0)
  detail_vert_count := i32(0)
  detail_tri_count := i32(0)
  if dmesh != nil {
    detail_mesh_count = pmesh.npolys
    detail_vert_count = i32(len(dmesh.verts)) - i32(len(pmesh.verts))
    detail_tri_count = i32(len(dmesh.tris))
  }
  header_size := size_of(detour.Mesh_Header)
  verts_size := size_of([3]f32) * int(total_vert_count)
  polys_size := size_of(detour.Poly) * int(total_poly_count)
  links_size := size_of(detour.Link) * int(max_link_count)
  detail_meshes_size := size_of(detour.Poly_Detail) * int(detail_mesh_count)
  detail_verts_size := size_of([3]f32) * int(detail_vert_count)
  detail_tris_size := size_of(u8) * int(detail_tri_count) * 4
  bv_node_count := total_poly_count
  bv_tree_size := size_of(detour.BV_Node) * int(bv_node_count)
  off_mesh_cons_size :=
    size_of(detour.Off_Mesh_Connection) * int(stored_off_mesh_con_count)
  total_size :=
    header_size +
    verts_size +
    polys_size +
    links_size +
    detail_meshes_size +
    detail_verts_size +
    detail_tris_size +
    bv_tree_size +
    off_mesh_cons_size
  data := make([]u8, total_size)
  offset := 0
  header := cast(^detour.Mesh_Header)(raw_data(data)[offset:])
  offset += header_size
  header.magic = detour.DT_NAVMESH_MAGIC
  header.version = detour.DT_NAVMESH_VERSION
  header.x = params.tile_x
  header.y = params.tile_y
  header.layer = params.tile_layer
  header.user_id = params.user_id
  header.poly_count = total_poly_count
  header.vert_count = total_vert_count
  header.max_link_count = max_link_count
  header.detail_mesh_count = detail_mesh_count
  header.detail_vert_count = detail_vert_count
  header.detail_tri_count = detail_tri_count
  header.bv_node_count = bv_node_count
  header.off_mesh_con_count = stored_off_mesh_con_count
  header.off_mesh_base = pmesh.npolys
  header.walkable_height = params.walkable_height
  header.walkable_radius = params.walkable_radius
  header.walkable_climb = params.walkable_climb
  header.bmin = pmesh.bmin
  header.bmax = pmesh.bmax
  header.bv_quant_factor = 1.0 / cs
  verts := slice.from_ptr(
    cast(^[3]f32)(raw_data(data)[offset:]),
    int(total_vert_count),
  )
  offset += verts_size
  for v, i in pmesh.verts {
    verts[i] =
      pmesh.bmin + [3]f32{f32(v[0]) * cs, f32(v[1]) * ch, f32(v[2]) * cs}
  }
  vert_idx := len(pmesh.verts)
  for i in 0 ..< params.off_mesh_con_count {
    if off_mesh_con_class[i * 2 + 0] == 0xff {
      conn := params.off_mesh_con_verts[i]
      verts[vert_idx + 0] = conn.start
      verts[vert_idx + 1] = conn.end
      vert_idx += 2
    }
  }
  polys := slice.from_ptr(
    cast(^detour.Poly)(raw_data(data)[offset:]),
    int(total_poly_count),
  )
  offset += polys_size
  for i in 0 ..< pmesh.npolys {
    poly := &polys[i]
    poly.first_link = detour.DT_NULL_LINK
    poly.flags = pmesh.flags[i]
    detour.poly_set_area(poly, pmesh.areas[i])
    detour.poly_set_type(poly, detour.DT_POLYTYPE_GROUND)
    poly_base := i * nvp * 2
    for j in 0 ..< nvp {
      if pmesh.polys[poly_base + j] == recast.RC_MESH_NULL_IDX {
        break
      }
      // Verify polygon is within vertex limits (should never trigger with proper generation)
      assert(
        poly.vert_count < detour.DT_VERTS_PER_POLYGON,
        fmt.tprintf(
          "Polygon %d exceeds vertex limit: %d > %d",
          i,
          poly.vert_count + 1,
          detour.DT_VERTS_PER_POLYGON,
        ),
      )
      poly.verts[poly.vert_count] = pmesh.polys[poly_base + j]
      if pmesh.polys[poly_base + nvp + j] & 0x8000 != 0 {
        poly.neis[poly.vert_count] = 0
      } else if pmesh.polys[poly_base + nvp + j] != recast.RC_MESH_NULL_IDX {
        // Recast poly index + 1 (0 = no neighbor); resolved to Detour index in connect_int_links
        poly.neis[poly.vert_count] = pmesh.polys[poly_base + nvp + j] + 1
      } else {
        poly.neis[poly.vert_count] = 0
      }
      poly.vert_count += 1
    }
  }
  poly_idx := pmesh.npolys
  vert_base := len(pmesh.verts)
  for i in 0 ..< params.off_mesh_con_count {
    if off_mesh_con_class[i * 2 + 0] == 0xff {
      poly := &polys[poly_idx]
      poly.vert_count = 2
      poly.verts[0] = u16(vert_base + 0)
      poly.verts[1] = u16(vert_base + 1)
      poly.flags = params.off_mesh_con_flags[i]
      detour.poly_set_area(poly, params.off_mesh_con_areas[i])
      detour.poly_set_type(poly, detour.DT_POLYTYPE_OFFMESH_CONNECTION)
      poly.first_link = detour.DT_NULL_LINK
      poly_idx += 1
      vert_base += 2
    }
  }
  offset += links_size
  if dmesh != nil {
    detail_meshes := slice.from_ptr(
      cast(^detour.Poly_Detail)(raw_data(data)[offset:]),
      int(detail_mesh_count),
    )
    offset += detail_meshes_size
    for i in 0 ..< pmesh.npolys {
      detail := &detail_meshes[i]
      mesh_info := dmesh.meshes[i]
      detail.vert_base = mesh_info[0]
      detail.tri_base = mesh_info[2]
      detail.vert_count = u8(mesh_info[1])
      detail.tri_count = u8(mesh_info[3])
    }
    detail_verts := slice.from_ptr(
      cast(^[3]f32)(raw_data(data)[offset:]),
      int(detail_vert_count),
    )
    offset += detail_verts_size
    for i in 0 ..< detail_vert_count {
      detail_verts[i] = dmesh.verts[len(pmesh.verts) + int(i)]
    }
    detail_tris := slice.from_ptr(
      cast(^[4]u8)(raw_data(data)[offset:]),
      int(detail_tri_count),
    )
    offset += detail_tris_size
    for i in 0 ..< detail_tri_count {
      detail_tris[i] = dmesh.tris[i]
    }
  }
  if bv_node_count > 0 {
    bv_tree := slice.from_ptr(
      cast(^detour.BV_Node)(raw_data(data)[offset:]),
      int(bv_node_count),
    )
    build_bv_tree(pmesh, bv_tree, bv_node_count, dmesh)
  }
  offset += bv_tree_size
  if stored_off_mesh_con_count > 0 {
    off_mesh_cons := slice.from_ptr(
      cast(^detour.Off_Mesh_Connection)(raw_data(data)[offset:]),
      int(stored_off_mesh_con_count),
    )
    con_idx := 0
    for i in 0 ..< params.off_mesh_con_count {
      if off_mesh_con_class[i * 2 + 0] == 0xff {
        con := &off_mesh_cons[con_idx]
        con.poly = u16(pmesh.npolys + i32(con_idx))
        conn := params.off_mesh_con_verts[i]
        con.start = conn.start
        con.end = conn.end
        con.rad = params.off_mesh_con_rad[i]
        if params.off_mesh_con_dir[i] != 0 {
          con.flags = detour.DT_OFFMESH_CON_BIDIR
        } else {
          con.flags = 0
        }
        con.side = off_mesh_con_class[i * 2 + 1]
        con.user_id = params.off_mesh_con_user_id[i]
        con_idx += 1
      }
    }
  }
  validation_result := detour.validate_tile_data(data)
  if !validation_result.valid {
    log.errorf("Created tile data failed validation:")
    for i in 0 ..< validation_result.error_count {
      log.errorf("  - %s", validation_result.errors[i])
    }
    return nil, {.Invalid_Param}
  }
  parsed_header, parse_status := detour.parse_mesh_header(data)
  if !detour.status_succeeded(parse_status) {
    log.errorf("Created tile data failed header parsing: %v", parse_status)
    return nil, {.Invalid_Param}
  }
  if parsed_header.poly_count != total_poly_count ||
     parsed_header.vert_count != total_vert_count ||
     parsed_header.max_link_count != max_link_count {
    log.errorf(
      "Header validation failed: counts don't match (poly: %d vs %d, vert: %d vs %d, links: %d vs %d)",
      parsed_header.poly_count,
      total_poly_count,
      parsed_header.vert_count,
      total_vert_count,
      parsed_header.max_link_count,
      max_link_count,
    )
    return nil, {.Invalid_Param}
  }
  log.infof(
    "Navigation mesh tile created successfully (size: %d bytes)",
    len(data),
  )
  return data, {.Success}
}

@(private = "file")
Off_Mesh_Connection_Verts :: struct {
  start: [3]f32,
  end:   [3]f32,
}

@(private)
Create_Nav_Mesh_Data_Params :: struct {
  poly_mesh:            ^recast.Poly_Mesh,
  poly_mesh_detail:     ^recast.Poly_Mesh_Detail,
  off_mesh_con_verts:   []Off_Mesh_Connection_Verts,
  off_mesh_con_rad:     []f32,
  off_mesh_con_flags:   []u16,
  off_mesh_con_areas:   []u8,
  off_mesh_con_dir:     []u8,
  off_mesh_con_user_id: []u32,
  off_mesh_con_count:   i32,
  user_id:              u32,
  tile_x:               i32,
  tile_y:               i32,
  tile_layer:           i32,
  walkable_height:      f32,
  walkable_radius:      f32,
  walkable_climb:       f32,
}

@(private = "file")
classify_off_mesh_connections :: proc(
  pmesh: ^recast.Poly_Mesh,
  params: ^Create_Nav_Mesh_Data_Params,
  class: []u8,
) {
  if params.off_mesh_con_count == 0 {
    return
  }
  hmin := f32(math.F32_MAX)
  hmax := f32(-math.F32_MAX)
  for v in pmesh.verts {
    h := pmesh.bmin[1] + f32(v[1]) * pmesh.ch
    hmin = min(hmin, h)
    hmax = max(hmax, h)
  }
  // Expand bounds by walkable climb to account for connection tolerance
  hmin -= params.walkable_climb
  hmax += params.walkable_climb
  bmin := [3]f32{pmesh.bmin[0], hmin, pmesh.bmin[2]}
  bmax := [3]f32{pmesh.bmax[0], hmax, pmesh.bmax[2]}
  for i in 0 ..< params.off_mesh_con_count {
    conn := params.off_mesh_con_verts[i]
    class[i * 2 + 0] = classify_off_mesh_point(conn.start, bmin, bmax)
    class[i * 2 + 1] = classify_off_mesh_point(conn.end, bmin, bmax)
    if class[i * 2 + 0] == 0xff {
      if conn.start[1] < bmin[1] || conn.start[1] > bmax[1] {
        class[i * 2 + 0] = 0
      }
    }
  }
}

@(private = "file")
classify_off_mesh_point :: proc(pt: [3]f32, bmin: [3]f32, bmax: [3]f32) -> u8 {
  XP :: u8(1 << 0)
  ZP :: u8(1 << 1)
  XM :: u8(1 << 2)
  ZM :: u8(1 << 3)
  outcode := u8(0)
  if pt[0] >= bmax[0] do outcode |= XP
  if pt[2] >= bmax[2] do outcode |= ZP
  if pt[0] < bmin[0] do outcode |= XM
  if pt[2] < bmin[2] do outcode |= ZM
  switch outcode {
  case XP:
    return 0
  case XP | ZP:
    return 1
  case ZP:
    return 2
  case XM | ZP:
    return 3
  case XM:
    return 4
  case XM | ZM:
    return 5
  case ZM:
    return 6
  case XP | ZM:
    return 7
  }
  return 0xff
}

@(private)
create_nav_mesh :: proc(
  params: ^Create_Nav_Mesh_Data_Params,
) -> (
  ^detour.Nav_Mesh,
  detour.Status,
) {
  data, status := create_nav_mesh_data(params)
  if !detour.status_succeeded(status) {
    return nil, status
  }
  nav_mesh := new(detour.Nav_Mesh)
  nav_params := detour.Nav_Mesh_Params {
    orig        = params.poly_mesh.bmin,
    tile_width  = params.poly_mesh.bmax[0] - params.poly_mesh.bmin[0],
    tile_height = params.poly_mesh.bmax[2] - params.poly_mesh.bmin[2],
    max_tiles   = 1,
    max_polys   = 1024,
  }
  status = detour.nav_mesh_init(nav_mesh, &nav_params)
  if !detour.status_succeeded(status) {
    free(nav_mesh)
    delete(data)
    return nil, status
  }
  _, status = detour.nav_mesh_add_tile(nav_mesh, data, detour.DT_TILE_FREE_DATA)
  if !detour.status_succeeded(status) {
    detour.nav_mesh_destroy(nav_mesh)
    free(nav_mesh)
    return nil, status
  }
  return nav_mesh, {.Success}
}

@(private)
build_bv_tree :: proc(
  pmesh: ^recast.Poly_Mesh,
  nodes: []detour.BV_Node,
  node_count: i32,
  dmesh: ^recast.Poly_Mesh_Detail = nil,
) {
  if node_count <= 0 || pmesh.npolys <= 0 {
    return
  }
  cs := pmesh.cs
  quant_factor := 1.0 / cs
  if pmesh.npolys <= 32 {
    build_bv_tree_flat(pmesh, nodes, node_count, quant_factor, dmesh)
  } else {
    build_bv_tree_hierarchical(pmesh, nodes, node_count, quant_factor)
  }
}

@(private = "file")
build_bv_tree_flat :: proc(
  pmesh: ^recast.Poly_Mesh,
  nodes: []detour.BV_Node,
  node_count: i32,
  quant_factor: f32,
  dmesh: ^recast.Poly_Mesh_Detail = nil,
) {
  nvp := pmesh.nvp
  for i in 0 ..< int(min(node_count, pmesh.npolys)) {
    node := &nodes[i]
    if dmesh != nil {
      bounds := calc_detail_mesh_bounds(dmesh, i, pmesh.bmin, quant_factor)
      node.bmin = bounds.min
      node.bmax = bounds.max
    } else {
      poly_base := i32(i) * nvp * 2
      bounds := calc_polygon_bounds_fast(pmesh, poly_base, nvp, quant_factor)
      node.bmin = bounds.min
      node.bmax = bounds.max
    }
    node.i = i32(i)
  }
}

@(private = "file")
build_bv_tree_hierarchical :: proc(
  pmesh: ^recast.Poly_Mesh,
  nodes: []detour.BV_Node,
  node_count: i32,
  quant_factor: f32,
) {
  nvp := pmesh.nvp
  poly_info := make([]BV_Poly_Info, pmesh.npolys)
  defer delete(poly_info)
  for i in 0 ..< pmesh.npolys {
    info := &poly_info[i]
    info.index = i
    poly_base := i * nvp * 2
    bounds := calc_polygon_bounds_fast(pmesh, poly_base, nvp, quant_factor)
    info.bounds = bounds
    info.center = [3]u16 {
      (bounds.min[0] + bounds.max[0]) / 2,
      (bounds.min[1] + bounds.max[1]) / 2,
      (bounds.min[2] + bounds.max[2]) / 2,
    }
  }
  next_node_idx := i32(0)
  build_bv_node_recursive(poly_info, nodes, &next_node_idx, 0, pmesh.npolys)
}

@(private = "file")
build_bv_node_recursive :: proc(
  poly_info: []BV_Poly_Info,
  nodes: []detour.BV_Node,
  next_idx: ^i32,
  start: i32,
  end: i32,
) -> i32 {
  node_idx := next_idx^
  next_idx^ += 1
  if node_idx >= i32(len(nodes)) {
    return -1
  }
  node := &nodes[node_idx]
  poly_count := end - start
  if poly_count > 0 {
    node.bmin = poly_info[start].bounds.min
    node.bmax = poly_info[start].bounds.max
    for i in start + 1 ..< end {
      info := &poly_info[i]
      node.bmin = linalg.min(node.bmin, info.bounds.min)
      node.bmax = linalg.max(node.bmax, info.bounds.max)
    }
  }
  MAX_LEAF_SIZE :: 8
  if poly_count <= MAX_LEAF_SIZE {
    if poly_count == 1 {
      node.i = poly_info[start].index
    } else {
      node.i = poly_info[start].index
    }
    return node_idx
  }
  axis := find_best_split_axis(poly_info[start:end])
  mid := partition_polygons_by_axis(poly_info[start:end], axis) + start
  if mid == start || mid == end {
    mid = start + poly_count / 2
  }
  left_child := build_bv_node_recursive(poly_info, nodes, next_idx, start, mid)
  right_child := build_bv_node_recursive(poly_info, nodes, next_idx, mid, end)
  if right_child >= 0 {
    node.i = -(right_child + 1)
  } else {
    node.i = poly_info[start].index
  }
  return node_idx
}

@(private = "file")
BV_Poly_Info :: struct {
  index:  i32,
  bounds: BV_Bounds_U16,
  center: [3]u16,
}

@(private = "file")
BV_Bounds_U16 :: struct {
  min: [3]u16,
  max: [3]u16,
}

@(private = "file")
calc_detail_mesh_bounds :: proc(
  dmesh: ^recast.Poly_Mesh_Detail,
  poly_idx: int,
  bmin: [3]f32,
  quant_factor: f32,
) -> BV_Bounds_U16 {
  bounds: BV_Bounds_U16
  mesh_info := dmesh.meshes[poly_idx]
  vert_base := mesh_info[0]
  vert_count := mesh_info[1]
  if vert_count == 0 {
    bounds.min = {0, 0, 0}
    bounds.max = {1, 1, 1}
    return bounds
  }
  first_vert := dmesh.verts[vert_base]
  min_bounds := first_vert
  max_bounds := first_vert
  for j in 1 ..< vert_count {
    v := dmesh.verts[vert_base + j]
    min_bounds = linalg.min(min_bounds, v)
    max_bounds = linalg.max(max_bounds, v)
  }
  for k in 0 ..< 3 {
    quantized_min := i32((min_bounds[k] - bmin[k]) * quant_factor)
    quantized_max := i32((max_bounds[k] - bmin[k]) * quant_factor)
    bounds.min[k] = u16(clamp(quantized_min, 0, 0xffff))
    bounds.max[k] = u16(clamp(quantized_max, 0, 0xffff))
  }
  return bounds
}

@(private)
calc_polygon_bounds_fast :: proc(
  pmesh: ^recast.Poly_Mesh,
  poly_base: i32,
  nvp: i32,
  quant_factor: f32,
) -> BV_Bounds_U16 {
  bounds: BV_Bounds_U16
  bounds.min = {65535, 65535, 65535}
  bounds.max = {0, 0, 0}
  vertex_count := 0
  for j in 0 ..< nvp {
    vert_idx := pmesh.polys[poly_base + j]
    if vert_idx == recast.RC_MESH_NULL_IDX {
      break
    }
    v := pmesh.verts[vert_idx]
    quant_coords := [3]u16{v[0], v[1], v[2]}
    bounds.min = linalg.min(bounds.min, quant_coords)
    bounds.max = linalg.max(bounds.max, quant_coords)
    vertex_count += 1
  }
  if vertex_count == 0 {
    bounds.min = {0, 0, 0}
    bounds.max = {1, 1, 1}
  } else {
    // CRITICAL: Remap Y coordinate as C++ does (lines 230-231 in DetourNavMeshBuilder.cpp)
    ch_cs_ratio := pmesh.ch / pmesh.cs
    bounds.min[1] = u16(math.floor(f32(bounds.min[1]) * ch_cs_ratio))
    bounds.max[1] = u16(math.ceil(f32(bounds.max[1]) * ch_cs_ratio))
  }
  return bounds
}

@(private = "file")
find_best_split_axis :: proc(poly_info: []BV_Poly_Info) -> int {
  if len(poly_info) < 2 {
    return 0
  }
  variance := [3]f32{0, 0, 0}
  mean := [3]f32{0, 0, 0}
  for info in poly_info {
    for i in 0 ..< 3 {
      mean[i] += f32(info.center[i])
    }
  }
  inv_count := 1.0 / f32(len(poly_info))
  for i in 0 ..< 3 {
    mean[i] *= inv_count
  }
  for info in poly_info {
    for i in 0 ..< 3 {
      diff := f32(info.center[i]) - mean[i]
      variance[i] += diff * diff
    }
  }
  best_axis := 0
  for i in 1 ..< 3 {
    if variance[i] > variance[best_axis] {
      best_axis = i
    }
  }
  return best_axis
}

@(private = "file")
partition_polygons_by_axis :: proc(
  poly_info: []BV_Poly_Info,
  axis: int,
) -> i32 {
  if len(poly_info) < 2 {
    return 1
  }
  if axis == 0 {
    slice.sort_by(poly_info, proc(a, b: BV_Poly_Info) -> bool {
      return a.center[0] < b.center[0]
    })
  } else if axis == 1 {
    slice.sort_by(poly_info, proc(a, b: BV_Poly_Info) -> bool {
      return a.center[1] < b.center[1]
    })
  } else {
    slice.sort_by(poly_info, proc(a, b: BV_Poly_Info) -> bool {
      return a.center[2] < b.center[2]
    })
  }
  return i32(len(poly_info) / 2)
}

@(private)
bake_and_save_navmesh :: proc(
  pmesh: ^recast.Poly_Mesh,
  dmesh: ^recast.Poly_Mesh_Detail,
  walkable_height, walkable_radius, walkable_climb: f32,
  filepath: string,
) -> bool {
  params := Create_Nav_Mesh_Data_Params {
    poly_mesh          = pmesh,
    poly_mesh_detail   = dmesh,
    walkable_height    = walkable_height,
    walkable_radius    = walkable_radius,
    walkable_climb     = walkable_climb,
    tile_x             = 0,
    tile_y             = 0,
    tile_layer         = 0,
    user_id            = 0,
    off_mesh_con_count = 0,
  }
  nav_data, create_status := create_nav_mesh_data(&params)
  if !detour.status_succeeded(create_status) {
    log.error("Failed to create navigation mesh data")
    return false
  }
  defer delete(nav_data)
  nav_mesh := new(detour.Nav_Mesh)
  defer {
    detour.nav_mesh_destroy(nav_mesh)
    free(nav_mesh)
  }
  mesh_params := detour.Nav_Mesh_Params {
    orig        = pmesh.bmin,
    tile_width  = pmesh.bmax.x - pmesh.bmin.x,
    tile_height = pmesh.bmax.z - pmesh.bmin.z,
    max_tiles   = 1,
    max_polys   = 1024,
  }
  init_status := detour.nav_mesh_init(nav_mesh, &mesh_params)
  if !detour.status_succeeded(init_status) {
    log.error("Failed to initialize navigation mesh")
    return false
  }
  // Make a copy of nav_data since nav_mesh_add_tile may take ownership
  nav_data_copy := make([]u8, len(nav_data))
  copy(nav_data_copy, nav_data)
  _, add_status := detour.nav_mesh_add_tile(
    nav_mesh,
    nav_data_copy,
    detour.DT_TILE_FREE_DATA,
  )
  if !detour.status_succeeded(add_status) {
    log.error("Failed to add tile to navigation mesh")
    delete(nav_data_copy)
    return false
  }
  return detour.save_navmesh_to_file(nav_mesh, filepath)
}
