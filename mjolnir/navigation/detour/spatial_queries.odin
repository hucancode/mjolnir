package detour

import "../../geometry"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

// Query_Filter selects polygons by include/exclude flags and weighs traversal by per-area cost.
Query_Filter :: struct {
  area_cost:     [DT_MAX_AREAS]f32,
  include_flags: u16,
  exclude_flags: u16,
}

// Raycast_Hit is a raycast result: hit parameter t, wall normal and the polygons visited.
Raycast_Hit :: struct {
  t:              f32,
  hit_normal:     [3]f32,
  hit_edge_index: i32,
  path:           []Poly_Ref,
  path_count:     i32,
  path_cost:      f32,
}

@(private = "file")
Raycast_Options :: enum u8 {
  Use_Costs = 0x01,
}

@(private = "file")
Poly_Query :: struct {
  process:   proc(
    ref: Poly_Ref,
    tile: ^Mesh_Tile,
    poly: ^Poly,
    user_data: rawptr,
  ),
  user_data: rawptr,
}

// query_filter_init resets a filter to include all flags, exclude none and use unit area costs.
query_filter_init :: proc(filter: ^Query_Filter) {
  filter.include_flags = 0xffff
  filter.exclude_flags = 0
  for i in 0 ..< DT_MAX_AREAS do filter.area_cost[i] = 1.0
}

@(private)
query_filter_pass_filter :: proc(
  filter: ^Query_Filter,
  ref: Poly_Ref,
  tile: ^Mesh_Tile,
  poly: ^Poly,
) -> bool {
  return(
    (poly.flags & filter.include_flags) != 0 &&
    (poly.flags & filter.exclude_flags) == 0 \
  )
}

@(private)
query_filter_get_cost :: proc(
  filter: ^Query_Filter,
  pa, pb: [3]f32,
  prev_ref: Poly_Ref,
  prev_tile: ^Mesh_Tile,
  prev_poly: ^Poly,
  cur_ref: Poly_Ref,
  cur_tile: ^Mesh_Tile,
  cur_poly: ^Poly,
  next_ref: Poly_Ref,
  next_tile: ^Mesh_Tile,
  next_poly: ^Poly,
) -> f32 {
  cost := linalg.distance(pa, pb)
  area := poly_get_area(cur_poly)
  if area < DT_MAX_AREAS do cost *= filter.area_cost[area]
  return cost
}

// find_nearest_poly returns the polygon nearest to center within half_extents, and the closest point on it.
find_nearest_poly :: proc(
  query: ^Nav_Mesh_Query,
  center: [3]f32,
  half_extents: [3]f32,
  filter: ^Query_Filter,
) -> (
  status: Status,
  nearest_ref: Poly_Ref,
  nearest_pt: [3]f32,
) {
  nearest_ref = INVALID_POLY_REF
  nearest_pt = center
  bmin := center - half_extents
  bmax := center + half_extents
  tx0, ty0, _ := calc_tile_loc(query.nav_mesh, bmin)
  tx1, ty1, _ := calc_tile_loc(query.nav_mesh, bmax)
  nearest_dist_sqr := f32(math.F32_MAX)
  for ty in ty0 ..= ty1 {
    for tx in tx0 ..= tx1 {
      tile := get_tile_at(query.nav_mesh, tx, ty, 0)
      if tile == nil || tile.header == nil do continue
      poly_refs := make([]Poly_Ref, 128)
      defer delete(poly_refs)
      poly_count := query_polygons_in_tile(
        query.nav_mesh,
        tile,
        bmin,
        bmax,
        poly_refs,
        128,
        filter,
      )
      for i in 0 ..< poly_count {
        ref := poly_refs[i]
        tile_poly, poly, poly_status := get_tile_and_poly_by_ref(
          query.nav_mesh,
          ref,
        )
        if !status_succeeded(poly_status) do continue
        closest_pt, _ := closest_point_on_polygon(tile_poly, poly, center)
        dist_sqr := linalg.length2(center - closest_pt)
        if dist_sqr < nearest_dist_sqr {
          nearest_dist_sqr = dist_sqr
          nearest_ref = ref
          nearest_pt = closest_pt
        }
      }
    }
  }
  return {.Success}, nearest_ref, nearest_pt
}

// query_polygons collects polygons overlapping the box around center that pass the filter.
query_polygons :: proc(
  query: ^Nav_Mesh_Query,
  center: [3]f32,
  half_extents: [3]f32,
  filter: ^Query_Filter,
  polys: []Poly_Ref,
) -> (
  status: Status,
  poly_count: i32,
) {
  poly_count = 0
  bmin := center - half_extents
  bmax := center + half_extents
  tx0, ty0, _ := calc_tile_loc(query.nav_mesh, bmin)
  tx1, ty1, _ := calc_tile_loc(query.nav_mesh, bmax)
  for ty in ty0 ..= ty1 {
    for tx in tx0 ..= tx1 {
      tile := get_tile_at(query.nav_mesh, tx, ty, 0)
      if tile == nil || tile.header == nil do continue
      remaining := i32(len(polys)) - poly_count
      if remaining <= 0 do break
      tile_poly_count := query_polygons_in_tile(
        query.nav_mesh,
        tile,
        bmin,
        bmax,
        polys[poly_count:],
        remaining,
        filter,
      )
      poly_count += tile_poly_count
    }
  }
  return {.Success}, poly_count
}

// raycast walks the mesh from start_pos toward end_pos and reports the first wall hit.
raycast :: proc(
  query: ^Nav_Mesh_Query,
  start_ref: Poly_Ref,
  start_pos, end_pos: [3]f32,
  filter: ^Query_Filter,
  options: u32,
  path: []Poly_Ref,
  max_path: i32,
) -> (
  status: Status,
  hit: Raycast_Hit,
  path_count: i32,
) {
  path_count = 0
  hit.t = math.F32_MAX
  hit.path_cost = 0
  hit.hit_edge_index = -1
  if !is_valid_poly_ref(query.nav_mesh, start_ref) do return {.Invalid_Param}, hit, 0
  cur_ref := start_ref
  cur_pos := start_pos
  dir := end_pos - start_pos
  ray_len := linalg.length(dir)
  if ray_len < 1e-6 {
    hit.t = 0.0
    return {.Success}, hit, path_count
  }
  ray_dir := dir / ray_len
  if max_path > 0 {
    path[0] = start_ref
    path_count = 1
  }
  cur_t := f32(0)
  prev_ref := INVALID_POLY_REF
  for cur_t < ray_len {
    tile, poly, poly_status := get_tile_and_poly_by_ref(
      query.nav_mesh,
      cur_ref,
    )
    if !status_succeeded(poly_status) do break
    next_ref := INVALID_POLY_REF
    next_t := ray_len
    hit_edge := -1
    for i in 0 ..< int(poly.vert_count) {
      va := tile.verts[poly.verts[i]]
      vb := tile.verts[poly.verts[(i + 1) % int(poly.vert_count)]]
      edge_t, intersects := geometry.ray_segment_intersect_2d(
        start_pos,
        ray_dir,
        va,
        vb,
      )
      if intersects && edge_t > cur_t && edge_t < next_t {
        link := poly.first_link
        neighbor_found := false
        link_iterations := 0
        max_link_iterations := 32
        for link != DT_NULL_LINK &&
            link_iterations < max_link_iterations {
          link_iterations += 1
          if get_link_edge(tile, link) == u8(i) {
            neighbor_ref := get_link_poly_ref(tile, link)
            if neighbor_ref != INVALID_POLY_REF && neighbor_ref != prev_ref {
              neighbor_tile, neighbor_poly, neighbor_status :=
                get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
              if status_succeeded(neighbor_status) &&
                 query_filter_pass_filter(
                   filter,
                   neighbor_ref,
                   neighbor_tile,
                   neighbor_poly,
                 ) {
                next_ref = neighbor_ref
                next_t = edge_t
                neighbor_found = true
                break
              }
            }
          }
          link = get_next_link(tile, link)
        }
        if !neighbor_found {
          hit.t = edge_t / ray_len
          hit.hit_edge_index = i32(i)
          edge_dir := vb - va
          hit.hit_normal = linalg.normalize([3]f32{edge_dir.z, 0, -edge_dir.x})
          return {.Success}, hit, path_count
        }
      }
    }
    if next_ref == INVALID_POLY_REF do break
    prev_ref = cur_ref
    cur_ref = next_ref
    cur_t = next_t
    cur_pos = start_pos + ray_dir * cur_t
    if path_count < max_path {
      path[path_count] = cur_ref
      path_count += 1
    }
    if (options & DT_RAYCAST_USE_COSTS) != 0 {
      prev_cost := hit.path_cost
      segment_cost := query_filter_get_cost(
        filter,
        start_pos + ray_dir * (cur_t - 0.01),
        cur_pos,
        INVALID_POLY_REF,
        nil,
        nil,
        cur_ref,
        tile,
        poly,
        INVALID_POLY_REF,
        nil,
        nil,
      )
      hit.path_cost = prev_cost + segment_cost
    }
  }
  hit.t = 1.0
  return {.Success}, hit, path_count
}

@(private = "file")
query_polygons_in_tile :: proc(
  nav_mesh: ^Nav_Mesh,
  tile: ^Mesh_Tile,
  qmin, qmax: [3]f32,
  polys: []Poly_Ref,
  max_polys: i32,
  filter: ^Query_Filter,
) -> i32 {
  count := i32(0)
  base := get_poly_ref_base(nav_mesh, tile)
  for i in 0 ..< int(tile.header.poly_count) {
    if count >= max_polys do break
    poly := &tile.polys[i]
    ref := base | Poly_Ref(i)
    if filter != nil && !query_filter_pass_filter(filter, ref, tile, poly) do continue
    poly_min := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}
    poly_max := [3]f32{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
    for j in 0 ..< int(poly.vert_count) {
      vertex_idx := poly.verts[j]
      if vertex_idx >= u16(len(tile.verts)) do break
      vert := tile.verts[vertex_idx]
      poly_min = linalg.min(poly_min, vert)
      poly_max = linalg.max(poly_max, vert)
    }
    if geometry.overlap_bounds(qmin, qmax, poly_min, poly_max) {
      polys[count] = ref
      count += 1
    }
  }
  return count
}

@(private = "file")
query_polygons_in_tile_bv :: proc(
  nav_mesh: ^Nav_Mesh,
  tile: ^Mesh_Tile,
  qmin, qmax: [3]f32,
  polys: []Poly_Ref,
  max_polys: i32,
) -> i32 {
  count := i32(0)
  base := get_poly_ref_base(nav_mesh, tile)
  factor := tile.header.bv_quant_factor
  iqmin := geometry.quantize_float(qmin - tile.header.bmin, factor)
  iqmax := geometry.quantize_float(qmax - tile.header.bmin, factor)
  stack := make([]i32, 32)
  defer delete(stack)
  stack_size := 0
  if len(tile.bv_tree) > 0 {
    stack[0] = 0
    stack_size = 1
  }
  for stack_size > 0 {
    node_index := stack[stack_size - 1]
    stack_size -= 1
    if node_index < 0 || node_index >= i32(len(tile.bv_tree)) do continue
    node := &tile.bv_tree[node_index]
    node_min := [3]i32{i32(node.bmin[0]), i32(node.bmin[1]), i32(node.bmin[2])}
    node_max := [3]i32{i32(node.bmax[0]), i32(node.bmax[1]), i32(node.bmax[2])}
    overlap := geometry.overlap_bounds(
      iqmin,
      iqmax,
      node_min,
      node_max,
    )
    if !overlap do continue
    if node.i >= 0 {
      if count < max_polys {
        polys[count] = base | Poly_Ref(node.i)
        count += 1
      }
    } else {
      child1 := (-node.i) - 1
      child2 := child1 + 1
      if stack_size < 30 && child1 >= 0 && child1 < i32(len(tile.bv_tree)) {
        stack[stack_size] = child1
        stack_size += 1
        if stack_size < 30 && child2 >= 0 && child2 < i32(len(tile.bv_tree)) {
          stack[stack_size] = child2
          stack_size += 1
        }
      }
    }
  }
  return count
}

// closest_point_on_polygon returns the point of a tile polygon nearest to pos and whether pos is inside it.
closest_point_on_polygon :: proc(
  tile: ^Mesh_Tile,
  poly: ^Poly,
  pos: [3]f32,
) -> (
  [3]f32,
  bool,
) {
  verts := make([][3]f32, poly.vert_count)
  defer delete(verts)
  for i in 0 ..< int(poly.vert_count) {
    verts[i] = tile.verts[poly.verts[i]]
  }
  inside := geometry.point_in_polygon_2d(pos, verts)
  if inside {
    avg_y := f32(0)
    for v in verts do avg_y += v.y
    avg_y /= f32(len(verts))
    return {pos.x, avg_y, pos.z}, true
  }
  closest := pos
  closest_dist_sqr := f32(math.F32_MAX)
  for i in 0 ..< int(poly.vert_count) {
    va, vb := verts[i], verts[(i + 1) % int(poly.vert_count)]
    edge_closest := geometry.closest_point_on_segment_2d(pos, va, vb)
    dist_sqr := linalg.length2((edge_closest - pos).xz)
    if dist_sqr < closest_dist_sqr {
      closest_dist_sqr = dist_sqr
      closest = edge_closest
    }
  }
  return closest, false
}

// get_poly_height returns the surface height of polygon ref.
get_poly_height :: proc(
  query: ^Nav_Mesh_Query,
  ref: Poly_Ref,
  pos: [3]f32,
) -> (
  height: f32,
  status: Status,
) {
  if !is_valid_poly_ref(query.nav_mesh, ref) do return 0, {.Invalid_Param}
  tile, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
  if !status_succeeded(poly_status) do return 0, poly_status
  if tile.detail_meshes == nil || len(tile.detail_meshes) == 0 {
    avg_height := f32(0)
    for i in 0 ..< int(poly.vert_count) do avg_height += tile.verts[poly.verts[i]].y
    return avg_height / f32(poly.vert_count), {.Success}
  }
  poly_index := u32(ref) & u32(tile.header.poly_count - 1)
  if poly_index >= u32(len(tile.detail_meshes)) do return 0, {.Invalid_Param}
  detail := &tile.detail_meshes[poly_index]
  for i in 0 ..< int(detail.tri_count) {
    tri_idx := detail.tri_base + u32(i)
    if tri_idx >= u32(len(tile.detail_tris)) do continue
    tri := &tile.detail_tris[tri_idx]
    verts: [3][3]f32
    for j in 0 ..< 3 {
      if tri[j] < poly.vert_count {
        verts[j] = tile.verts[poly.verts[tri[j]]]
      } else {
        detail_vert_idx := detail.vert_base + u32(tri[j] - poly.vert_count)
        if detail_vert_idx < u32(len(tile.detail_verts)) {
          verts[j] = tile.detail_verts[detail_vert_idx]
        }
      }
    }
    if geometry.point_in_triangle_2d(pos, verts[0], verts[1], verts[2]) {
      bary := geometry.barycentric_2d(pos, verts[0], verts[1], verts[2])
      height = linalg.dot(bary, [3]f32{verts[0].y, verts[1].y, verts[2].y})
      return height, {.Success}
    }
  }
  center := calc_poly_center(tile, poly)
  return center.y, {.Success}
}

// find_distance_to_wall finds the nearest wall within max_radius of center_pos.
find_distance_to_wall :: proc(
  query: ^Nav_Mesh_Query,
  start_ref: Poly_Ref,
  center_pos: [3]f32,
  max_radius: f32,
  filter: ^Query_Filter,
) -> (
  hit_dist: f32,
  hit_pos: [3]f32,
  hit_normal: [3]f32,
  status: Status,
) {
  if !is_valid_poly_ref(query.nav_mesh, start_ref) do return 0, {}, {}, {.Invalid_Param}
  hit_dist = max_radius
  visited := make(map[Poly_Ref]bool)
  defer delete(visited)
  visited[start_ref] = true
  stack := make([]Poly_Ref, 256)
  defer delete(stack)
  stack_size := 1
  stack[0] = start_ref
  for stack_size > 0 {
    stack_size -= 1
    cur_ref := stack[stack_size]
    tile, poly, poly_status := get_tile_and_poly_by_ref(
      query.nav_mesh,
      cur_ref,
    )
    if !status_succeeded(poly_status) do continue
    for i in 0 ..< int(poly.vert_count) {
      va, vb :=
        tile.verts[poly.verts[i]],
        tile.verts[poly.verts[(i + 1) % int(poly.vert_count)]]
      is_wall := true
      poly_idx := get_poly_index(query.nav_mesh, cur_ref)
      link := get_first_link(tile, i32(poly_idx))
      for link != DT_NULL_LINK {
        if get_link_edge(tile, link) == u8(i) {
          neighbor_ref := get_link_poly_ref(tile, link)
          if neighbor_ref != INVALID_POLY_REF {
            neighbor_tile, neighbor_poly, neighbor_status :=
              get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
            if status_succeeded(neighbor_status) &&
               query_filter_pass_filter(
                 filter,
                 neighbor_ref,
                 neighbor_tile,
                 neighbor_poly,
               ) {
              is_wall = false
              if _, exists := visited[neighbor_ref];
                 !exists && stack_size < 255 {
                visited[neighbor_ref] = true
                stack[stack_size] = neighbor_ref
                stack_size += 1
              }
              break
            }
          }
        }
        link = get_next_link(tile, link)
      }
      if is_wall {
        closest := geometry.closest_point_on_segment_2d(center_pos, va, vb)
        dist := linalg.length(center_pos - closest)
        if dist < hit_dist {
          hit_dist = dist
          hit_pos = closest
          edge := vb - va
          hit_normal = linalg.normalize([3]f32{edge.z, 0, -edge.x})
        }
      }
    }
    center := calc_poly_center(tile, poly)
    if linalg.length2(center - center_pos) > max_radius * max_radius do break
  }
  return hit_dist, hit_pos, hit_normal, {.Success}
}

// find_local_neighbourhood collects polygons reachable within radius of center.
find_local_neighbourhood :: proc(
  query: ^Nav_Mesh_Query,
  start_ref: Poly_Ref,
  center_pos: [3]f32,
  radius: f32,
  filter: ^Query_Filter,
  result_ref: []Poly_Ref,
  result_parent: []Poly_Ref,
  max_result: i32,
) -> (
  result_count: i32,
  status: Status,
) {
  if !is_valid_poly_ref(query.nav_mesh, start_ref) || max_result <= 0 {
    return 0, {.Invalid_Param}
  }
  result_count = 0
  visited := make(map[Poly_Ref]bool)
  defer delete(visited)
  queue := make([]struct {
      ref:    Poly_Ref,
      parent: Poly_Ref,
    }, 256)
  defer delete(queue)
  queue_head, queue_tail := 0, 1
  queue[0] = {start_ref, INVALID_POLY_REF}
  visited[start_ref] = true
  for queue_head < queue_tail && result_count < max_result {
    cur := queue[queue_head]
    queue_head += 1
    tile, poly, poly_status := get_tile_and_poly_by_ref(
      query.nav_mesh,
      cur.ref,
    )
    if !status_succeeded(poly_status) do continue
    center := calc_poly_center(tile, poly)
    if linalg.length2(center - center_pos) > radius * radius {
      continue
    }
    result_ref[result_count] = cur.ref
    result_parent[result_count] = cur.parent
    result_count += 1
    for i in 0 ..< int(poly.vert_count) {
      poly_idx := get_poly_index(query.nav_mesh, cur.ref)
      link := get_first_link(tile, i32(poly_idx))
      for link != DT_NULL_LINK {
        if get_link_edge(tile, link) == u8(i) {
          neighbor_ref := get_link_poly_ref(tile, link)
          if _, exists := visited[neighbor_ref]; !exists {
            neighbor_tile, neighbor_poly, neighbor_status :=
              get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
            if status_succeeded(neighbor_status) &&
               query_filter_pass_filter(
                 filter,
                 neighbor_ref,
                 neighbor_tile,
                 neighbor_poly,
               ) {
              visited[neighbor_ref] = true
              if queue_tail < 256 {
                queue[queue_tail] = {neighbor_ref, cur.ref}
                queue_tail += 1
              }
            }
          }
          break
        }
        link = get_next_link(tile, link)
      }
    }
  }
  return result_count, {.Success}
}

// find_polys_around_circle collects polygons overlapping a circle, using Dijkstra search.
find_polys_around_circle :: proc(
  query: ^Nav_Mesh_Query,
  start_ref: Poly_Ref,
  center_pos: [3]f32,
  radius: f32,
  filter: ^Query_Filter,
  result_ref: []Poly_Ref,
  result_parent: []Poly_Ref,
  result_cost: []f32,
  max_result: i32,
) -> (
  result_count: i32,
  status: Status,
) {
  if !is_valid_poly_ref(query.nav_mesh, start_ref) || max_result <= 0 {
    return 0, {.Invalid_Param}
  }
  if i32(len(result_ref)) < max_result ||
     i32(len(result_parent)) < max_result ||
     i32(len(result_cost)) < max_result {
    return 0, {.Invalid_Param}
  }
  result_count = 0
  radius_sqr := radius * radius
  pathfinding_context_clear(&query.pf_context)
  node_queue_clear(&query.open_list)
  start_node := create_node(&query.pf_context, start_ref)
  if start_node == nil {
    return 0, {.Out_Of_Nodes}
  }
  start_tile, start_poly, poly_status := get_tile_and_poly_by_ref(
    query.nav_mesh,
    start_ref,
  )
  if !status_succeeded(poly_status) do return 0, poly_status
  start_node.pos, _ = closest_point_on_polygon(
    start_tile,
    start_poly,
    center_pos,
  )
  start_node.cost = 0
  start_node.total = linalg.length2(start_node.pos - center_pos)
  start_node.flags = {.Open}
  start_node.parent_id = INVALID_POLY_REF
  node_queue_push(
    &query.open_list,
    {start_ref, start_node.cost, start_node.total},
  )
  MAX_ITERATIONS :: 100
  it := 0
  for !node_queue_empty(&query.open_list) && it < MAX_ITERATIONS {
    it += 1
    if result_count >= max_result do break
    best := node_queue_pop(&query.open_list)
    if best.ref == INVALID_POLY_REF do break
    current := get_node(&query.pf_context, best.ref)
    if current == nil || .Closed in current.flags do continue
    current.flags |= {.Closed}
    current.flags &= ~{.Open}
    dist_sqr := linalg.length2(current.pos - center_pos)
    if dist_sqr <= radius_sqr {
      if result_count < max_result {
        result_ref[result_count] = current.id
        result_parent[result_count] = current.parent_id
        result_cost[result_count] = current.cost
        result_count += 1
      }
    }
    cur_tile, cur_poly, cur_status := get_tile_and_poly_by_ref(
      query.nav_mesh,
      current.id,
    )
    if !status_succeeded(cur_status) do continue
    poly_idx := get_poly_index(query.nav_mesh, current.id)
    link := get_first_link(cur_tile, i32(poly_idx))
    for link != DT_NULL_LINK {
      neighbor_ref := get_link_poly_ref(cur_tile, link)
      if neighbor_ref != INVALID_POLY_REF {
        neighbor_tile, neighbor_poly, neighbor_status :=
          get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
        if status_succeeded(neighbor_status) &&
           query_filter_pass_filter(
             filter,
             neighbor_ref,
             neighbor_tile,
             neighbor_poly,
           ) {
          neighbor_node := get_node(&query.pf_context, neighbor_ref)
          if neighbor_node == nil {
            neighbor_node = create_node(&query.pf_context, neighbor_ref)
            if neighbor_node == nil do break
            neighbor_node.pos = calc_poly_center(neighbor_tile, neighbor_poly)
          }
          if .Closed in neighbor_node.flags {
            link = get_next_link(cur_tile, link)
            continue
          }
          step_cost := linalg.length(current.pos - neighbor_node.pos)
          new_cost := current.cost + step_cost
          new_dist_sqr := linalg.length2(neighbor_node.pos - center_pos)
          new_total := new_cost + math.sqrt(new_dist_sqr)
          if .Open in neighbor_node.flags && new_cost >= neighbor_node.cost {
            link = get_next_link(cur_tile, link)
            continue
          }
          neighbor_node.cost = new_cost
          neighbor_node.total = new_total
          neighbor_node.parent_id = current.id
          neighbor_node.flags |= {.Open}
          node_queue_push(
            &query.open_list,
            {neighbor_ref, neighbor_node.cost, neighbor_node.total},
          )
        }
      }
      link = get_next_link(cur_tile, link)
    }
  }
  return result_count, {.Success}
}

// find_polys_around_shape collects polygons overlapping a convex shape, using Dijkstra search.
find_polys_around_shape :: proc(
  query: ^Nav_Mesh_Query,
  start_ref: Poly_Ref,
  verts: [][3]f32,
  filter: ^Query_Filter,
  result_ref: []Poly_Ref,
  result_parent: []Poly_Ref,
  result_cost: []f32,
  max_result: i32,
) -> (
  result_count: i32,
  status: Status,
) {
  if !is_valid_poly_ref(query.nav_mesh, start_ref) ||
     len(verts) < 3 ||
     max_result <= 0 {
    return 0, {.Invalid_Param}
  }
  result_count = 0
  center: [3]f32
  for vert in verts do center += vert
  center /= f32(len(verts))
  pathfinding_context_clear(&query.pf_context)
  node_queue_clear(&query.open_list)
  start_node := create_node(&query.pf_context, start_ref)
  if start_node == nil do return 0, {.Out_Of_Nodes}
  start_tile, start_poly, poly_status := get_tile_and_poly_by_ref(
    query.nav_mesh,
    start_ref,
  )
  if !status_succeeded(poly_status) do return 0, poly_status
  start_node.pos, _ = closest_point_on_polygon(start_tile, start_poly, center)
  start_node.cost = 0
  start_node.total = linalg.length(start_node.pos - center)
  start_node.flags = {.Open}
  start_node.parent_id = INVALID_POLY_REF
  node_queue_push(
    &query.open_list,
    {start_ref, start_node.cost, start_node.total},
  )
  for !node_queue_empty(&query.open_list) {
    best := node_queue_pop(&query.open_list)
    if best.ref == INVALID_POLY_REF do break
    current := get_node(&query.pf_context, best.ref)
    if current == nil || .Closed in current.flags {
      continue
    }
    current.flags |= {.Closed}
    current.flags &= ~{.Open}
    if geometry.point_in_polygon_2d(current.pos, verts) {
      if result_count < max_result {
        result_ref[result_count] = current.id
        result_parent[result_count] = current.parent_id
        result_cost[result_count] = current.cost
        result_count += 1
      }
    }
    cur_tile, cur_poly, cur_status := get_tile_and_poly_by_ref(
      query.nav_mesh,
      current.id,
    )
    if !status_succeeded(cur_status) do continue
    poly_idx := get_poly_index(query.nav_mesh, current.id)
    link := get_first_link(cur_tile, i32(poly_idx))
    for link != DT_NULL_LINK {
      neighbor_ref := get_link_poly_ref(cur_tile, link)
      if neighbor_ref != INVALID_POLY_REF {
        neighbor_tile, neighbor_poly, neighbor_status :=
          get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
        if status_succeeded(neighbor_status) &&
           query_filter_pass_filter(
             filter,
             neighbor_ref,
             neighbor_tile,
             neighbor_poly,
           ) {
          neighbor_node := get_node(&query.pf_context, neighbor_ref)
          if neighbor_node == nil {
            neighbor_node = create_node(&query.pf_context, neighbor_ref)
            if neighbor_node == nil {
              break
            }
            neighbor_node.pos = calc_poly_center(neighbor_tile, neighbor_poly)
          }
          if .Closed in neighbor_node.flags {
            link = get_next_link(cur_tile, link)
            continue
          }
          step_cost := linalg.length(current.pos - neighbor_node.pos)
          new_cost := current.cost + step_cost
          new_total := new_cost + linalg.length(neighbor_node.pos - center)
          if .Open in neighbor_node.flags && new_cost >= neighbor_node.cost {
            link = get_next_link(cur_tile, link)
            continue
          }
          neighbor_node.cost = new_cost
          neighbor_node.total = new_total
          neighbor_node.parent_id = current.id
          neighbor_node.flags |= {.Open}
          node_queue_push(
            &query.open_list,
            {neighbor_ref, neighbor_node.cost, neighbor_node.total},
          )
        }
      }
      link = get_next_link(cur_tile, link)
    }
  }
  return result_count, {.Success}
}

// get_path_from_dijkstra_search returns the polygon path from the search start to end_ref.
get_path_from_dijkstra_search :: proc(
  query: ^Nav_Mesh_Query,
  end_ref: Poly_Ref,
  path: []Poly_Ref,
  max_path: i32,
) -> (
  path_count: i32,
  status: Status,
) {
  if !is_valid_poly_ref(query.nav_mesh, end_ref) || max_path <= 0 {
    return 0, {.Invalid_Param}
  }
  end_node := get_node(&query.pf_context, end_ref)
  if end_node == nil || .Closed not_in end_node.flags {
    return 0, {.Invalid_Param}
  }
  result_status, result_path_count := get_path_to_node(
    query,
    end_node,
    path,
    max_path,
  )
  return result_path_count, result_status
}

// get_poly_wall_segments returns the non-portal edges of a polygon.
get_poly_wall_segments :: proc(
  query: ^Nav_Mesh_Query,
  ref: Poly_Ref,
  filter: ^Query_Filter,
  segment_verts: [][6]f32,
  segment_refs: []Poly_Ref,
  max_segments: i32,
) -> (
  segment_count: i32,
  status: Status,
) {
  if !is_valid_poly_ref(query.nav_mesh, ref) || max_segments <= 0 {
    return 0, {.Invalid_Param}
  }
  segment_count = 0
  tile, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
  if !status_succeeded(poly_status) do return 0, poly_status
  poly_idx := get_poly_index(query.nav_mesh, ref)
  for i in 0 ..< min(int(max_segments), int(poly.vert_count)) {
    va := tile.verts[poly.verts[i]]
    vb := tile.verts[poly.verts[(i + 1) % int(poly.vert_count)]]
    neighbor_ref := INVALID_POLY_REF
    link := poly.first_link
    link_iterations := 0
    max_link_iterations := 32
    for link != DT_NULL_LINK && link_iterations < max_link_iterations {
      link_iterations += 1
      if get_link_edge(tile, link) == u8(i) {
        potential_neighbor := get_link_poly_ref(tile, link)
        if potential_neighbor != INVALID_POLY_REF {
          neighbor_tile, neighbor_poly, neighbor_status :=
            get_tile_and_poly_by_ref(query.nav_mesh, potential_neighbor)
          if status_succeeded(neighbor_status) &&
             query_filter_pass_filter(
               filter,
               potential_neighbor,
               neighbor_tile,
               neighbor_poly,
             ) {
            neighbor_ref = potential_neighbor
            break
          }
        }
      }
      link = get_next_link(tile, link)
    }
    segment_verts[segment_count] = {va.x, va.y, va.z, vb.x, vb.y, vb.z}
    segment_refs[segment_count] = neighbor_ref
    segment_count += 1
  }
  return segment_count, {.Success}
}

@(private = "file")
is_in_closed_list :: proc(
  query: ^Nav_Mesh_Query,
  ref: Poly_Ref,
) -> bool {
  if query == nil do return false
  node := get_node(&query.pf_context, ref)
  return node != nil && .Closed in node.flags
}
