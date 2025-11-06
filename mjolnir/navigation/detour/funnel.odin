package navigation_detour

import "../../geometry"
import "../recast"
import "core:math"
import "core:math/linalg"

find_straight_path :: proc(
  query: ^Nav_Mesh_Query,
  start_pos, end_pos: [3]f32,
  path: []recast.Poly_Ref,
  path_count: i32,
  straight_path: []Straight_Path_Point,
  straight_path_flags: []u8,
  straight_path_refs: []recast.Poly_Ref,
  max_straight_path: i32,
  options: u32,
) -> (
  status: recast.Status,
  straight_path_count: i32,
) {
  straight_path_count = 0
  if query == nil || query.nav_mesh == nil do return {.Invalid_Param}, 0
  if path_count == 0 || path[0] == recast.INVALID_POLY_REF || max_straight_path <= 0 do return {.Invalid_Param}, 0
  // Clamp start and end positions to polygon boundaries
  closest_start_pos, start_status := closest_point_on_poly_boundary_nav(
    query,
    path[0],
    start_pos,
  )
  if recast.status_failed(start_status) do return {.Invalid_Param}, 0
  closest_end_pos, end_status := closest_point_on_poly_boundary_nav(
    query,
    path[path_count - 1],
    end_pos,
  )
  if recast.status_failed(end_status) do return {.Invalid_Param}, 0
  // Add start point
  stat: recast.Status
  n_straight_path := i32(0)
  if n_straight_path < max_straight_path {
    straight_path[n_straight_path] = {
      pos   = closest_start_pos,
      flags = u8(Straight_Path_Flags.Start),
      ref   = path[0],
    }
    n_straight_path += 1
  } else {
    stat |= {.Buffer_Too_Small}
  }
  // Special case: single polygon
  if path_count == 1 {
    if n_straight_path < max_straight_path {
      straight_path[n_straight_path] = {
        pos   = closest_end_pos,
        flags = u8(Straight_Path_Flags.End),
        ref   = path[0],
      }
      n_straight_path += 1
    } else {
      stat |= {.Buffer_Too_Small}
    }
    straight_path_count = n_straight_path
    return stat | {.Success}, straight_path_count
  }
  // Funnel algorithm for multi-polygon path
  portal_apex := closest_start_pos
  portal_left := closest_start_pos
  portal_right := closest_start_pos
  apex_index := i32(0)
  left_index := i32(0)
  right_index := i32(0)
  left_poly_type := u8(0)
  right_poly_type := u8(0)
  for i := i32(0); i < path_count; i += 1 {
    left: [3]f32
    right: [3]f32
    to_type := u8(0)
    if i + 1 < path_count {
      // Get portal between path[i] and path[i+1]
      from_type: u8
      portal_status: recast.Status
      left, right, from_type, portal_status = get_portal_points(
        query,
        path[i],
        path[i + 1],
      )
      if recast.status_failed(portal_status) {
        // Failed to get portal - add end point
        closest_on_poly, _ := closest_point_on_poly_boundary_nav(
          query,
          path[i],
          closest_end_pos,
        )
        if n_straight_path < max_straight_path {
          straight_path[n_straight_path] = {
            pos   = closest_on_poly,
            flags = u8(Straight_Path_Flags.End),
            ref   = path[i],
          }
          n_straight_path += 1
        }
        straight_path_count = n_straight_path
        return stat | {.Success, .Partial_Result}, straight_path_count
      }
      // Skip if starting very close to portal
      if i == 0 {
        dist_sqr, _ := geometry.point_segment_distance2_2d(
          portal_apex,
          left,
          right,
        )
        if dist_sqr < 0.001 * 0.001 do continue
      }
    } else {
      // End of path
      left = closest_end_pos
      right = closest_end_pos
      to_type = u8(Straight_Path_Flags.End)
    }
    // Update right vertex
    if geometry.perpendicular_cross_2d(portal_apex, portal_right, right) <=
       0.0 {
      if geometry.vector_equal(portal_apex, portal_right) ||
         geometry.perpendicular_cross_2d(portal_apex, portal_left, right) >
           0.0 {
        // Tighten funnel
        portal_right = right
        if i + 1 < path_count do right_poly_type = to_type
        right_index = i
      } else {
        // Right over left - add left vertex and restart
        if n_straight_path == 0 ||
           !geometry.vector_equal(
               portal_left,
               straight_path[n_straight_path - 1].pos,
             ) {
          if n_straight_path < max_straight_path {
            straight_path[n_straight_path] = {
              pos   = portal_left,
              flags = left_poly_type,
              ref   = path[left_index],
            }
            n_straight_path += 1
          } else {
            stat |= {.Buffer_Too_Small}
          }
        }
        // Advance apex and restart
        portal_apex = portal_left
        apex_index = left_index
        portal_left = portal_apex
        portal_right = portal_apex
        left_index = apex_index
        right_index = apex_index
        left_poly_type = 0
        right_poly_type = 0
        i = apex_index
        continue
      }
    }
    // Update left vertex
    if geometry.perpendicular_cross_2d(portal_apex, portal_left, left) >= 0.0 {
      if geometry.vector_equal(portal_apex, portal_left) ||
         geometry.perpendicular_cross_2d(portal_apex, portal_right, left) <
           0.0 {
        // Tighten funnel
        portal_left = left
        if i + 1 < path_count do left_poly_type = to_type
        left_index = i
      } else {
        // Left over right - add right vertex and restart
        if n_straight_path < max_straight_path {
          straight_path[n_straight_path] = {
            pos   = portal_right,
            flags = right_poly_type,
            ref   = path[right_index],
          }
          n_straight_path += 1
        } else {
          stat |= {.Buffer_Too_Small}
        }
        // Advance apex and restart
        portal_apex = portal_right
        apex_index = right_index
        portal_left = portal_apex
        portal_right = portal_apex
        left_index = apex_index
        right_index = apex_index
        left_poly_type = 0
        right_poly_type = 0
        i = apex_index
        continue
      }
    }
  }
  // Add end point
  if n_straight_path < max_straight_path {
    straight_path[n_straight_path] = {
      pos   = closest_end_pos,
      flags = u8(Straight_Path_Flags.End),
      ref   = 0,
    }
    n_straight_path += 1
  } else {
    stat |= {.Buffer_Too_Small}
  }
  straight_path_count = n_straight_path
  // Copy to output arrays
  if straight_path_flags != nil {
    for i in 0 ..< n_straight_path {
      if int(i) < len(straight_path_flags) {
        straight_path_flags[i] = straight_path[i].flags
      }
    }
  }
  if straight_path_refs != nil {
    for i in 0 ..< n_straight_path {
      if int(i) < len(straight_path_refs) {
        straight_path_refs[i] = straight_path[i].ref
      }
    }
  }
  if stat == {} do stat |= {.Success}
  return stat, straight_path_count
}

get_portal_points :: proc(
  query: ^Nav_Mesh_Query,
  from: recast.Poly_Ref,
  to: recast.Poly_Ref,
) -> (
  left: [3]f32,
  right: [3]f32,
  portal_type: u8,
  status: recast.Status,
) {
  from_tile, from_poly, from_status := get_tile_and_poly_by_ref(
    query.nav_mesh,
    from,
  )
  if recast.status_failed(from_status) do return {}, {}, 0, from_status
  to_tile, to_poly, to_status := get_tile_and_poly_by_ref(query.nav_mesh, to)
  if recast.status_failed(to_status) do return {}, {}, 0, to_status
  // Find link from 'from' to 'to'
  link := from_poly.first_link
  for link != recast.DT_NULL_LINK {
    if int(link) >= len(from_tile.links) do break
    link_info := &from_tile.links[link]
    if link_info.ref == to {
      // Found the connection - extract edge vertices
      link_edge := link_info.edge
      if int(link_edge) >= int(from_poly.vert_count) {
        link = link_info.next
        continue
      }
      v0_idx := from_poly.verts[link_edge]
      v1_idx := from_poly.verts[(link_edge + 1) % u8(from_poly.vert_count)]
      if int(v0_idx) >= len(from_tile.verts) ||
         int(v1_idx) >= len(from_tile.verts) {
        link = link_info.next
        continue
      }
      v0_pos := from_tile.verts[v0_idx]
      v1_pos := from_tile.verts[v1_idx]
      // Return vertices in correct order for portal
      left = v1_pos
      right = v0_pos
      portal_type = 0
      return left, right, portal_type, {.Success}
    }
    link = link_info.next
  }
  // Fallback: check neighbor references for same-tile polygons
  from_salt, from_tile_idx, from_poly_idx := decode_poly_id(
    query.nav_mesh,
    from,
  )
  to_salt, to_tile_idx, to_poly_idx := decode_poly_id(query.nav_mesh, to)
  if from_tile_idx == to_tile_idx {
    for i in 0 ..< int(from_poly.vert_count) {
      nei := from_poly.neis[i]
      nei_idx: u32
      if nei & 0x8000 != 0 {
        nei_idx = u32(nei & 0x7fff)
      } else if nei > 0 && nei <= 0x3f {
        nei_idx = u32(nei - 1)
      } else {
        continue
      }
      if nei_idx == to_poly_idx {
        v0_idx := from_poly.verts[i]
        v1_idx := from_poly.verts[(i + 1) % int(from_poly.vert_count)]
        if int(v0_idx) >= len(from_tile.verts) || int(v1_idx) >= len(from_tile.verts) do continue
        va := from_tile.verts[v0_idx]
        vb := from_tile.verts[v1_idx]
        left = vb
        right = va
        portal_type = 0
        return left, right, portal_type, {.Success}
      }
    }
  }
  return {}, {}, 0, {.Invalid_Param}
}

calc_poly_center :: proc(tile: ^Mesh_Tile, poly: ^Poly) -> [3]f32 {
  center := [3]f32{0, 0, 0}
  for i in 0 ..< int(poly.vert_count) {
    center += tile.verts[poly.verts[i]]
  }
  if poly.vert_count > 0 do center /= f32(poly.vert_count)
  return center
}

move_along_surface :: proc(
  query: ^Nav_Mesh_Query,
  start_ref: recast.Poly_Ref,
  start_pos: [3]f32,
  end_pos: [3]f32,
  filter: ^Query_Filter,
  visited: []recast.Poly_Ref,
  max_visited: i32,
) -> (
  result_pos: [3]f32,
  visited_count: i32,
  status: recast.Status,
) {
  visited_count = 0
  result_pos = start_pos
  if !is_valid_poly_ref(query.nav_mesh, start_ref) do return result_pos, visited_count, {.Invalid_Param}
  tile, poly, tile_status := get_tile_and_poly_by_ref(
    query.nav_mesh,
    start_ref,
  )
  if recast.status_failed(tile_status) do return result_pos, visited_count, tile_status
  if max_visited > 0 {
    visited[0] = start_ref
    visited_count = 1
  }
  dir := end_pos - start_pos
  if linalg.length2(dir) < 1e-6 * 1e-6 do return result_pos, visited_count, {.Success}
  cur_pos := start_pos
  cur_ref := start_ref
  // Walk along surface using adaptive steps
  STEP_SIZE :: 0.1
  max_steps := i32(linalg.length(dir) / STEP_SIZE * 2)
  if max_steps < 10 do max_steps = 10
  if max_steps > 1000 do max_steps = 1000
  for iter := i32(0); iter < max_steps; iter += 1 {
    remaining := end_pos - cur_pos
    distance := linalg.length(remaining)
    if distance < 1e-6 do break
    // Take step toward goal
    step_size := min(STEP_SIZE, distance)
    step_dir := linalg.normalize(remaining)
    target_pos := cur_pos + step_dir * step_size
    // Project to current polygon
    closest_pos := closest_point_on_poly(query, cur_ref, target_pos)
    // Check if we left the current polygon
    if !point_in_polygon(query, cur_ref, closest_pos) {
      neighbor_ref, wall_hit := find_neighbor_across_edge(
        query,
        cur_ref,
        cur_pos,
        closest_pos,
        filter,
      )
      if neighbor_ref != recast.INVALID_POLY_REF {
        cur_ref = neighbor_ref
        if visited_count < max_visited {
          visited[visited_count] = cur_ref
          visited_count += 1
        }
      } else if wall_hit {
        break
      }
    }
    cur_pos = closest_pos
  }
  result_pos = cur_pos
  return result_pos, visited_count, {.Success}
}

closest_point_on_poly_boundary_nav :: proc(
  query: ^Nav_Mesh_Query,
  ref: recast.Poly_Ref,
  pos: [3]f32,
) -> (
  [3]f32,
  recast.Status,
) {
  tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
  if recast.status_failed(status) || tile == nil || poly == nil do return pos, status
  verts := make([][3]f32, poly.vert_count)
  defer delete(verts)
  for i in 0 ..< int(poly.vert_count) {
    verts[i] = tile.verts[poly.verts[i]]
  }
  edge_dist := make([]f32, poly.vert_count)
  defer delete(edge_dist)
  edge_t := make([]f32, poly.vert_count)
  defer delete(edge_t)
  for i in 0 ..< int(poly.vert_count) {
    j := (i + 1) % int(poly.vert_count)
    va := verts[i]
    vb := verts[j]
    dist_sqr, t := geometry.point_segment_distance2_2d(pos, va, vb)
    edge_dist[i] = dist_sqr
    edge_t[i] = t
  }
  inside := geometry.point_in_polygon_2d(pos, verts)
  if inside {
    return pos, {.Success}
  } else {
    min_dist := edge_dist[0]
    min_idx := 0
    for i in 1 ..< int(poly.vert_count) {
      if edge_dist[i] < min_dist {
        min_dist = edge_dist[i]
        min_idx = i
      }
    }
    j := (min_idx + 1) % int(poly.vert_count)
    va := verts[min_idx]
    vb := verts[j]
    result := linalg.lerp(va, vb, edge_t[min_idx])
    return result, {.Success}
  }
}

closest_point_on_poly :: proc(
  query: ^Nav_Mesh_Query,
  ref: recast.Poly_Ref,
  pos: [3]f32,
) -> [3]f32 {
  tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
  if recast.status_failed(status) do return pos
  verts := make([][3]f32, poly.vert_count)
  defer delete(verts)
  for i in 0 ..< int(poly.vert_count) {
    verts[i] = tile.verts[poly.verts[i]]
  }
  if geometry.point_in_polygon_2d(pos, verts) {
    // Inside - return with average Y
    avg_y := f32(0)
    for v in verts do avg_y += v.y
    avg_y /= f32(len(verts))
    return {pos.x, avg_y, pos.z}
  }
  // Outside - find closest point on edges
  closest := pos
  closest_dist_sqr := f32(math.F32_MAX)
  for i in 0 ..< int(poly.vert_count) {
    va := verts[i]
    vb := verts[(i + 1) % int(poly.vert_count)]
    edge_closest := geometry.closest_point_on_segment_2d(pos, va, vb)
    dist_sqr := linalg.length2(edge_closest.xz - pos.xz)
    if dist_sqr < closest_dist_sqr {
      closest_dist_sqr = dist_sqr
      closest = edge_closest
    }
  }
  return closest
}

point_in_polygon :: proc(
  query: ^Nav_Mesh_Query,
  ref: recast.Poly_Ref,
  pos: [3]f32,
) -> bool {
  tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
  if recast.status_failed(status) do return false
  verts := make([][3]f32, poly.vert_count)
  defer delete(verts)
  for i in 0 ..< int(poly.vert_count) {
    verts[i] = tile.verts[poly.verts[i]]
  }
  return geometry.point_in_polygon_2d(pos, verts)
}

find_neighbor_across_edge :: proc(
  query: ^Nav_Mesh_Query,
  ref: recast.Poly_Ref,
  start_pos: [3]f32,
  end_pos: [3]f32,
  filter: ^Query_Filter,
) -> (
  recast.Poly_Ref,
  bool,
) {
  tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
  if recast.status_failed(status) do return recast.INVALID_POLY_REF, false
  for i in 0 ..< int(poly.vert_count) {
    va := tile.verts[poly.verts[i]]
    vb := tile.verts[poly.verts[(i + 1) % int(poly.vert_count)]]
    if geometry.segment_segment_intersect_2d(start_pos, end_pos, va, vb) {
      link := poly.first_link
      for link != recast.DT_NULL_LINK {
        if get_link_edge(tile, link) == u8(i) {
          neighbor_ref := get_link_poly_ref(tile, link)
          if neighbor_ref != recast.INVALID_POLY_REF {
            neighbor_tile, neighbor_poly, neighbor_status :=
              get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
            if recast.status_succeeded(neighbor_status) &&
               query_filter_pass_filter(
                 filter,
                 neighbor_ref,
                 neighbor_tile,
                 neighbor_poly,
               ) {
              return neighbor_ref, false
            }
          }
        }
        link = get_next_link(tile, link)
      }
      return recast.INVALID_POLY_REF, true // hit wall
    }
  }
  return recast.INVALID_POLY_REF, false
}
