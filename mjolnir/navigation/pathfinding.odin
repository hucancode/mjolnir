package navigation

import "core:container/priority_queue"
import "core:log"
import "core:math"
import "core:slice"
import linalg "core:math/linalg"
import "../geometry"

// Node for A* pathfinding
PathNode :: struct {
  poly_ref:    PolyRef,
  position:    [3]f32,
  g_cost:      f32,    // Cost from start
  h_cost:      f32,    // Heuristic cost to goal
  f_cost:      f32,    // Total cost (g + h)
  parent:      PolyRef,
  flags:       u8,     // Open/closed flags
}

// Node flags
NODE_OPEN   :: 0x01
NODE_CLOSED :: 0x02

path_node_less :: proc(a, b: PathNode) -> bool {
  return a.f_cost < b.f_cost
}

// Query structure for pathfinding
PathQuery :: struct {
  mesh:         ^NavMesh,
  filter:       QueryFilter,
  open_list:    priority_queue.Priority_Queue(PathNode),
  nodes:        map[PolyRef]PathNode,
  max_nodes:    int,
}

// Heuristic scale factor (matching Detour's value)
H_SCALE :: 0.999

// Check if polygon passes filter (matching Detour's logic)
pass_filter :: proc(filter: ^QueryFilter, poly: ^Poly) -> bool {
  return (poly.flags & filter.include_flags) != 0 && (poly.flags & filter.exclude_flags) == 0
}

query_init :: proc(mesh: ^NavMesh, max_nodes: int = 2048) -> PathQuery {
  open_list := priority_queue.Priority_Queue(PathNode){}
  priority_queue.init(&open_list, path_node_less, priority_queue.default_swap_proc(PathNode))
  
  return PathQuery{
    mesh = mesh,
    filter = query_filter_default(),
    open_list = open_list,
    nodes = make(map[PolyRef]PathNode),
    max_nodes = max_nodes,
  }
}

query_deinit :: proc(query: ^PathQuery) {
  priority_queue.destroy(&query.open_list)
  delete(query.nodes)
}

// Find path using Detour-style algorithm
find_path :: proc(query: ^PathQuery, start_pos, end_pos: [3]f32) -> ([][3]f32, bool) {
  extent := [3]f32{2, 4, 2}
  
  // Find start and end polygons
  start_ref := find_nearest_poly_ref(query.mesh, start_pos, extent)
  if start_ref == 0 {
    log.warn("Could not find start polygon")
    return nil, false
  }
  
  end_ref := find_nearest_poly_ref(query.mesh, end_pos, extent)
  if end_ref == 0 {
    log.warn("Could not find end polygon")
    return nil, false
  }
  
  log.infof("find_path: Start position [%.2f, %.2f, %.2f] -> poly %x", start_pos.x, start_pos.y, start_pos.z, start_ref)
  log.infof("find_path: End position [%.2f, %.2f, %.2f] -> poly %x", end_pos.x, end_pos.y, end_pos.z, end_ref)
  
  if start_ref == end_ref {
    log.info("Start and end in same polygon, direct path")
    path := make([][3]f32, 2)
    path[0] = start_pos
    path[1] = end_pos
    return path, true
  }
  
  // Find polygon path
  poly_path := find_polygon_path(query, start_ref, end_ref, start_pos, end_pos)
  if len(poly_path) == 0 {
    log.warn("No path found")
    return nil, false
  }
  defer delete(poly_path)
  
  log.infof("find_path: Found polygon path with %d polygons", len(poly_path))
  
  // Debug: Log the polygon path
  for poly_ref, i in poly_path {
    center := get_poly_center(query.mesh, poly_ref)
    log.infof("  Polygon %d: %x at center [%.2f, %.2f, %.2f]", i, poly_ref, center.x, center.y, center.z)
  }
  
  // Convert polygon path to world positions using string pulling
  log.info("find_path: Starting string pulling...")
  path := string_pull_path(query.mesh, poly_path, start_pos, end_pos)
  log.infof("find_path: String pulling completed, path has %d points", len(path))
  
  // Debug: Log the final path
  for point, i in path {
    log.infof("  Waypoint %d: [%.2f, %.2f, %.2f]", i, point.x, point.y, point.z)
  }
  if len(path) == 0 {
    log.warn("String pulling failed, falling back to polygon centers")
    // Fallback to polygon centers
    path = make([][3]f32, len(poly_path))
    for poly_ref, i in poly_path {
      path[i] = get_poly_center(query.mesh, poly_ref)
    }
    // Set start and end positions
    if len(path) > 0 {
      path[0] = start_pos
      path[len(path)-1] = end_pos
    }
  }
  
  return path, true
}




// ===== NEW DETOUR-STYLE FUNCTIONS =====

// Find nearest polygon reference using Detour-style search
find_nearest_poly_ref :: proc(navmesh: ^NavMesh, pos: [3]f32, extent: [3]f32) -> PolyRef {
  // Search box bounds
  bmin := pos - extent
  bmax := pos + extent
  
  best_ref: PolyRef = 0
  best_distance_sqr: f32 = math.F32_MAX
  
  // Iterate through all tiles (simplified - no tile lookup optimization yet)
  for tile_idx in 0..<navmesh.max_tiles {
    tile := &navmesh.tiles[tile_idx]
    if tile.header == nil do continue
    
    // Check each polygon in the tile
    for poly_idx in 0..<tile.header.poly_count {
      poly := &tile.polys[poly_idx]
      
      // Skip degenerate polygons
      if poly.vert_count < 3 do continue
      
      // Calculate polygon bounds
      poly_bmin, poly_bmax := get_poly_bounds(tile, poly)
      
      // Check if polygon bounds overlap with search bounds
      if !bounds_overlap(bmin, bmax, poly_bmin, poly_bmax) do continue
      
      // Find closest point on polygon and calculate distance
      closest_pt, distance_sqr := closest_point_on_poly(tile, poly, pos)
      
      // Check if this is the best polygon so far
      if distance_sqr < best_distance_sqr {
        best_distance_sqr = distance_sqr
        best_ref = encode_poly_id(tile.salt, u32(tile_idx), u32(poly_idx))
      }
    }
  }
  
  return best_ref
}

// Get polygon bounding box
get_poly_bounds :: proc(tile: ^MeshTile, poly: ^Poly) -> ([3]f32, [3]f32) {
  if poly.vert_count == 0 do return {}, {}
  
  // Get first vertex
  vert_idx := poly.verts[0]
  if vert_idx >= u16(tile.header.vert_count) do return {}, {}
  
  bmin := [3]f32{
    tile.verts[vert_idx * 3 + 0],
    tile.verts[vert_idx * 3 + 1], 
    tile.verts[vert_idx * 3 + 2],
  }
  bmax := bmin
  
  // Expand bounds with remaining vertices
  for i in 1..<poly.vert_count {
    vert_idx = poly.verts[i]
    if vert_idx >= u16(tile.header.vert_count) do continue
    
    vert_pos := [3]f32{
      tile.verts[vert_idx * 3 + 0],
      tile.verts[vert_idx * 3 + 1],
      tile.verts[vert_idx * 3 + 2],
    }
    
    bmin = linalg.min(bmin, vert_pos)
    bmax = linalg.max(bmax, vert_pos)
  }
  
  return bmin, bmax
}

// Check if two bounding boxes overlap
bounds_overlap :: proc(amin, amax, bmin, bmax: [3]f32) -> bool {
  return !(amax.x < bmin.x || amin.x > bmax.x ||
           amax.y < bmin.y || amin.y > bmax.y ||
           amax.z < bmin.z || amin.z > bmax.z)
}

// Distance from point to line segment (2D)
distance_pt_seg_sqr_2d :: proc(pt: [3]f32, a: [3]f32, b: [3]f32) -> (f32, f32) {
  dx := b.x - a.x
  dz := b.z - a.z
  
  if dx*dx + dz*dz < 0.0001 {
    // Points are very close, just return distance to a
    dx2 := pt.x - a.x
    dz2 := pt.z - a.z
    return dx2*dx2 + dz2*dz2, 0
  }
  
  // Parameter t of closest point on segment
  t := ((pt.x - a.x) * dx + (pt.z - a.z) * dz) / (dx*dx + dz*dz)
  t = math.clamp(t, 0, 1)
  
  // Closest point
  closest_x := a.x + t * dx
  closest_z := a.z + t * dz
  
  // Distance squared
  dx3 := pt.x - closest_x
  dz3 := pt.z - closest_z
  
  return dx3*dx3 + dz3*dz3, t
}

// Point in polygon test using ray casting algorithm (2D)
point_in_polygon_2d :: proc(pt: [3]f32, verts: []f32, nverts: int) -> bool {
  c := false
  for i, j := 0, nverts-1; i < nverts; j, i = i, i+1 {
    vi_x := verts[i*3 + 0]
    vi_z := verts[i*3 + 2]
    vj_x := verts[j*3 + 0]
    vj_z := verts[j*3 + 2]
    
    if ((vi_z > pt.z) != (vj_z > pt.z)) &&
       (pt.x < (vj_x - vi_x) * (pt.z - vi_z) / (vj_z - vi_z) + vi_x) {
      c = !c
    }
  }
  return c
}

// Find closest point on polygon (matching Detour's closestPointOnPolyBoundary)
closest_point_on_poly :: proc(tile: ^MeshTile, poly: ^Poly, pos: [3]f32) -> ([3]f32, f32) {
  if poly.vert_count < 3 do return pos, math.F32_MAX
  
  // Collect vertices
  verts := make([]f32, poly.vert_count * 3)
  defer delete(verts)
  
  for i in 0..<poly.vert_count {
    vert_idx := poly.verts[i]
    if vert_idx >= u16(tile.header.vert_count) do continue
    
    verts[i*3 + 0] = tile.verts[vert_idx * 3 + 0]
    verts[i*3 + 1] = tile.verts[vert_idx * 3 + 1]
    verts[i*3 + 2] = tile.verts[vert_idx * 3 + 2]
  }
  
  // Check if point is inside polygon
  inside := point_in_polygon_2d(pos, verts, int(poly.vert_count))
  
  if inside {
    // Point is inside, return the point projected to polygon height
    // For now, use average height
    avg_y := f32(0)
    for i in 0..<poly.vert_count {
      avg_y += verts[i*3 + 1]
    }
    avg_y /= f32(poly.vert_count)
    
    closest := [3]f32{pos.x, avg_y, pos.z}
    diff := pos - closest
    // When over polygon, prefer based on height difference
    distance_sqr := diff.y * diff.y
    return closest, distance_sqr
  }
  
  // Point is outside, find closest edge
  best_dist_sqr := f32(math.F32_MAX)
  best_t := f32(0)
  best_edge := 0
  
  for i, j := 0, int(poly.vert_count)-1; i < int(poly.vert_count); j, i = i, i+1 {
    va := [3]f32{verts[j*3], verts[j*3+1], verts[j*3+2]}
    vb := [3]f32{verts[i*3], verts[i*3+1], verts[i*3+2]}
    
    dist_sqr, t := distance_pt_seg_sqr_2d(pos, va, vb)
    if dist_sqr < best_dist_sqr {
      best_dist_sqr = dist_sqr
      best_t = t
      best_edge = j
    }
  }
  
  // Calculate closest point on best edge
  j := best_edge
  i := (j + 1) % int(poly.vert_count)
  va := [3]f32{verts[j*3], verts[j*3+1], verts[j*3+2]}
  vb := [3]f32{verts[i*3], verts[i*3+1], verts[i*3+2]}
  
  closest := linalg.lerp(va, vb, best_t)
  diff := pos - closest
  distance_sqr := linalg.dot(diff, diff)
  
  return closest, distance_sqr
}

// Check if point is within polygon bounds (simplified)
point_in_poly_bounds :: proc(tile: ^MeshTile, poly: ^Poly, pos: [3]f32, extent: [3]f32) -> bool {
  if poly.vert_count < 3 do return false
  
  // Get polygon bounds
  min_bounds := [3]f32{pos.x - extent.x, pos.y - extent.y, pos.z - extent.z}
  max_bounds := [3]f32{pos.x + extent.x, pos.y + extent.y, pos.z + extent.z}
  
  // Check if any vertex is within bounds
  for i in 0..<poly.vert_count {
    vert_idx := poly.verts[i]
    if vert_idx >= u16(tile.header.vert_count) do continue
    
    vert_pos := [3]f32{
      tile.verts[vert_idx * 3 + 0],
      tile.verts[vert_idx * 3 + 1],
      tile.verts[vert_idx * 3 + 2],
    }
    
    if vert_pos.x >= min_bounds.x && vert_pos.x <= max_bounds.x &&
       vert_pos.y >= min_bounds.y && vert_pos.y <= max_bounds.y &&
       vert_pos.z >= min_bounds.z && vert_pos.z <= max_bounds.z {
      return true
    }
  }
  
  return false
}

// Get polygon center position
get_poly_center :: proc(navmesh: ^NavMesh, poly_ref: PolyRef) -> [3]f32 {
  tile_idx := decode_poly_id_tile(poly_ref)
  poly_idx := decode_poly_id_poly(poly_ref)
  
  if tile_idx >= u32(navmesh.max_tiles) do return {}
  
  tile := &navmesh.tiles[tile_idx]
  if tile.header == nil || poly_idx >= u32(tile.header.poly_count) do return {}
  
  poly := &tile.polys[poly_idx]
  if poly.vert_count == 0 do return {}
  
  center := [3]f32{}
  for i in 0..<poly.vert_count {
    vert_idx := poly.verts[i]
    if vert_idx >= u16(tile.header.vert_count) do continue
    
    vert_pos := [3]f32{
      tile.verts[vert_idx * 3 + 0],
      tile.verts[vert_idx * 3 + 1],
      tile.verts[vert_idx * 3 + 2],
    }
    center += vert_pos
  }
  
  return center / f32(poly.vert_count)
}

// Detour-style pathfinding algorithm
find_polygon_path :: proc(query: ^PathQuery, start_ref, end_ref: PolyRef, start_pos, end_pos: [3]f32) -> []PolyRef {
  log.infof("find_polygon_path: Searching from poly %x to poly %x", start_ref, end_ref)
  log.infof("  Start pos: [%.2f, %.2f, %.2f], End pos: [%.2f, %.2f, %.2f]", 
            start_pos.x, start_pos.y, start_pos.z, end_pos.x, end_pos.y, end_pos.z)
  
  start_center := get_poly_center(query.mesh, start_ref)
  end_center := get_poly_center(query.mesh, end_ref)
  log.infof("  Start poly center: [%.2f, %.2f, %.2f], End poly center: [%.2f, %.2f, %.2f]",
            start_center.x, start_center.y, start_center.z, end_center.x, end_center.y, end_center.z)
  
  // Log heuristic distance for debugging
  direct_dist := linalg.distance(start_pos, end_pos)
  log.infof("  Direct distance: %.2f", direct_dist)
  
  if start_ref == end_ref {
    log.info("find_polygon_path: Start and end are in same polygon")
    path := make([]PolyRef, 1)
    path[0] = start_ref
    return path
  }
  
  // Clear previous search state
  clear(&query.nodes)
  priority_queue.clear(&query.open_list)
  
  // Initialize start node
  start_node := PathNode{
    poly_ref = start_ref,
    position = start_pos,
    g_cost = 0,
    h_cost = linalg.distance(start_pos, end_pos) * H_SCALE,
    f_cost = 0,
    parent = 0,
    flags = NODE_OPEN,
  }
  start_node.f_cost = start_node.g_cost + start_node.h_cost
  
  query.nodes[start_ref] = start_node
  priority_queue.push(&query.open_list, start_node)
  
  best_node := start_node
  max_iterations := query.max_nodes
  iterations := 0
  
  for priority_queue.len(query.open_list) > 0 && max_iterations > 0 {
    max_iterations -= 1
    iterations += 1
    
    if iterations % 100 == 0 {
      log.debugf("A* progress: iteration %d, open list size: %d", iterations, priority_queue.len(query.open_list))
    }
    
    // Get best node from open list
    current := priority_queue.pop(&query.open_list)
    current.flags &= ~u8(NODE_OPEN)
    current.flags |= NODE_CLOSED
    query.nodes[current.poly_ref] = current
    
    if iterations <= 10 {  // Debug first few iterations
      log.infof("A* iter %d: current poly=%x, f_cost=%.2f, g_cost=%.2f, h_cost=%.2f, pos[%.2f,%.2f,%.2f]", 
                 iterations, current.poly_ref, current.f_cost, current.g_cost, current.h_cost,
                 current.position.x, current.position.y, current.position.z)
    }
    
    // Check if we reached the goal
    if current.poly_ref == end_ref {
      log.infof("A* found path to goal %x after %d iterations!", end_ref, iterations)
      best_node = current
      break
    }
    
    // Update best node if this one is closer to goal
    if current.h_cost < best_node.h_cost {
      best_node = current
    }
    
    // Expand neighbors
    expand_neighbors(query, current, end_ref, end_pos, iterations)
  }
  
  // Reconstruct path from best node
  log.infof("A* completed after %d iterations. Best node: poly=%x, h_cost=%.2f", 
            iterations, best_node.poly_ref, best_node.h_cost)
  
  if best_node.poly_ref != end_ref {
    log.warnf("A* did not reach goal! Goal was %x", end_ref)
    log.infof("  Explored %d nodes, %d still in open list", len(query.nodes), priority_queue.len(query.open_list))
  }
  
  return reconstruct_path_from_nodes(query, best_node)
}

// Expand neighbors for A* search
expand_neighbors :: proc(query: ^PathQuery, current: PathNode, end_ref: PolyRef, end_pos: [3]f32, iteration: int) {
  tile_idx := decode_poly_id_tile(current.poly_ref)
  poly_idx := decode_poly_id_poly(current.poly_ref)
  
  if tile_idx >= u32(query.mesh.max_tiles) do return
  
  tile := &query.mesh.tiles[tile_idx]
  if tile.header == nil || poly_idx >= u32(tile.header.poly_count) do return
  
  poly := &tile.polys[poly_idx]
  
  if poly.first_link == NULL_LINK {
    log.debugf("expand_neighbors: Polygon %x has no links", current.poly_ref)
  } else {
    log.debugf("expand_neighbors: Polygon %x first_link=%u", current.poly_ref, poly.first_link)
  }
  
  neighbor_count := 0
  
  // Iterate through polygon links
  for link_idx := poly.first_link; link_idx != NULL_LINK; link_idx = tile.links[link_idx].next {
    if link_idx >= u32(len(tile.links)) do break
    
    link := &tile.links[link_idx]
    neighbor_ref := link.ref
    
    if iteration <= 5 && neighbor_count < 5 {  // Debug neighbors for first few iterations
      log.infof("  Link %d: neighbor_ref=%x, edge=%d, parent=%x", link_idx, neighbor_ref, link.edge, current.parent)
    }
    
    if neighbor_ref == 0 {
      log.debugf("  Skipping null neighbor reference")
      continue
    }
    if neighbor_ref == current.parent {
      log.debugf("  Skipping parent polygon %x", neighbor_ref)
      continue
    }
    
    // Get neighbor polygon for filter check
    neighbor_tile_idx := decode_poly_id_tile(neighbor_ref)
    neighbor_poly_idx := decode_poly_id_poly(neighbor_ref)
    
    if neighbor_tile_idx >= u32(query.mesh.max_tiles) do continue
    neighbor_tile := &query.mesh.tiles[neighbor_tile_idx]
    if neighbor_tile.header == nil || neighbor_poly_idx >= u32(neighbor_tile.header.poly_count) do continue
    neighbor_poly := &neighbor_tile.polys[neighbor_poly_idx]
    
    // Apply filter (matching Detour's approach)
    poly_area := get_poly_area(neighbor_poly)
    if !pass_filter(&query.filter, neighbor_poly) {
      log.debugf("  Polygon %x failed filter check (flags=%x, area=%d, include=%x, exclude=%x)", 
                 neighbor_ref, neighbor_poly.flags, poly_area, 
                 query.filter.include_flags, query.filter.exclude_flags)
      continue
    }
    
    if neighbor_count < 3 {  // Debug successful neighbors
      log.debugf("  Polygon %x passed filter (flags=%x, area=%d)", neighbor_ref, neighbor_poly.flags, poly_area)
    }
    
    // Check if neighbor is already processed
    if neighbor_node, exists := query.nodes[neighbor_ref]; exists {
      if neighbor_node.flags & NODE_CLOSED != 0 {
        if neighbor_count < 3 {
          log.debugf("  Skipping already closed polygon %x", neighbor_ref)
        }
        continue
      }
    }
    
    // Calculate neighbor position (use edge midpoint for better accuracy)
    neighbor_pos := get_edge_midpoint(query.mesh, current.poly_ref, neighbor_ref)
    if neighbor_pos == {} {
      neighbor_pos = get_poly_center(query.mesh, neighbor_ref)  // Fallback
    }
    
    // Calculate costs (matching Detour's approach)
    base_move_cost := linalg.distance(current.position, neighbor_pos)
    area_cost := query.filter.area_cost[poly_area]
    move_cost := base_move_cost * area_cost
    new_g_cost := current.g_cost + move_cost
    
    // Special handling for goal node (matching Detour)
    new_h_cost: f32
    if neighbor_ref == end_ref {
      // Goal node: add cost to actual end position and zero heuristic
      end_cost := linalg.distance(neighbor_pos, end_pos)
      new_g_cost += end_cost
      new_h_cost = 0
    } else {
      // Regular node: standard heuristic with scaling
      new_h_cost = linalg.distance(neighbor_pos, end_pos) * H_SCALE
    }
    
    new_f_cost := new_g_cost + new_h_cost
    
    // Debug logging for cost analysis (first few neighbors)
    if iteration <= 5 && neighbor_count < 5 {
      log.infof("    Neighbor %x: pos[%.2f,%.2f,%.2f], base_cost=%.2f, area_cost=%.2f, g=%.2f, h=%.2f, f=%.2f",
                neighbor_ref, neighbor_pos.x, neighbor_pos.y, neighbor_pos.z,
                base_move_cost, area_cost, new_g_cost, new_h_cost, new_f_cost)
      
      // Also log why we might skip this neighbor
      if neighbor_node, exists := query.nodes[neighbor_ref]; exists {
        if new_g_cost >= neighbor_node.g_cost {
          log.infof("      -> Skipped: existing g_cost %.2f is better", neighbor_node.g_cost)
        }
      }
    }
    
    // Check if this path is better
    if neighbor_node, exists := query.nodes[neighbor_ref]; exists {
      if new_g_cost >= neighbor_node.g_cost do continue
    }
    
    // Create or update neighbor node
    neighbor_node := PathNode{
      poly_ref = neighbor_ref,
      position = neighbor_pos,
      g_cost = new_g_cost,
      h_cost = new_h_cost,
      f_cost = new_f_cost,
      parent = current.poly_ref,
      flags = NODE_OPEN,
    }
    
    query.nodes[neighbor_ref] = neighbor_node
    priority_queue.push(&query.open_list, neighbor_node)
    neighbor_count += 1
  }
  
  if neighbor_count == 0 && poly.first_link != NULL_LINK {
    log.warnf("expand_neighbors: Polygon %x has links but found no valid neighbors", current.poly_ref)
  }
}

// Reconstruct path from nodes
reconstruct_path_from_nodes :: proc(query: ^PathQuery, end_node: PathNode) -> []PolyRef {
  path := make([dynamic]PolyRef)
  
  current_ref := end_node.poly_ref
  for current_ref != 0 {
    append(&path, current_ref)
    
    if current_node, exists := query.nodes[current_ref]; exists {
      current_ref = current_node.parent
    } else {
      break
    }
  }
  
  // Reverse path to go from start to end
  slice.reverse(path[:])
  
  return path[:]
}

// Get constrained portal points to avoid extreme waypoints
get_constrained_portal_points :: proc(navmesh: ^NavMesh, poly_ref1, poly_ref2: PolyRef, 
                                     from_pos, to_pos: [3]f32) -> (left, right: [3]f32) {
  // Get the full portal edge
  full_left, full_right := get_portal_points(navmesh, poly_ref1, poly_ref2)
  
  // If the portal is reasonably sized, use it as is
  edge_length := linalg.distance(full_left, full_right)
  if edge_length <= 3.0 {
    return full_left, full_right
  }
  
  // For large portals, constrain based on the path direction
  // Project from_pos and to_pos onto the portal edge
  edge_dir := full_right - full_left
  edge_len_sq := linalg.dot(edge_dir, edge_dir)
  
  if edge_len_sq > 0.001 {
    // Project from_pos
    t_from := linalg.dot(from_pos - full_left, edge_dir) / edge_len_sq
    t_from = math.clamp(t_from, 0.1, 0.9)  // Keep away from extremes
    
    // Project to_pos
    t_to := linalg.dot(to_pos - full_left, edge_dir) / edge_len_sq
    t_to = math.clamp(t_to, 0.1, 0.9)
    
    // Ensure some minimum portal width
    t_min := math.min(t_from, t_to) - 0.1
    t_max := math.max(t_from, t_to) + 0.1
    t_min = math.clamp(t_min, 0, 1)
    t_max = math.clamp(t_max, 0, 1)
    
    // Ensure minimum width
    if t_max - t_min < 0.2 {
      center := (t_min + t_max) * 0.5
      t_min = center - 0.1
      t_max = center + 0.1
    }
    
    left := linalg.lerp(full_left, full_right, t_min)
    right := linalg.lerp(full_left, full_right, t_max)
    
    log.infof("  Constrained large portal from %.1f to range [%.2f,%.2f]", edge_length, t_min, t_max)
    return left, right
  }
  
  return full_left, full_right
}

// String pulling algorithm for path smoothing
string_pull_path :: proc(navmesh: ^NavMesh, poly_path: []PolyRef, start_pos, end_pos: [3]f32) -> [][3]f32 {
  log.debugf("string_pull_path: Processing path with %d polygons", len(poly_path))
  
  if len(poly_path) == 0 do return nil
  if len(poly_path) == 1 {
    path := make([][3]f32, 2)
    path[0] = start_pos
    path[1] = end_pos
    return path
  }
  
  // Clamp start and end positions to polygon boundaries (matching Detour)
  clamped_start := start_pos
  clamped_end := end_pos
  
  // Clamp start position to first polygon
  if len(poly_path) > 0 {
    first_tile_idx := decode_poly_id_tile(poly_path[0])
    first_poly_idx := decode_poly_id_poly(poly_path[0])
    if first_tile_idx < u32(navmesh.max_tiles) {
      first_tile := &navmesh.tiles[first_tile_idx]
      if first_tile.header != nil && first_poly_idx < u32(first_tile.header.poly_count) {
        first_poly := &first_tile.polys[first_poly_idx]
        clamped_start, _ = closest_point_on_poly(first_tile, first_poly, start_pos)
        log.debugf("Clamped start from [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f]", 
                  start_pos.x, start_pos.y, start_pos.z, clamped_start.x, clamped_start.y, clamped_start.z)
      }
    }
  }
  
  // Clamp end position to last polygon
  if len(poly_path) > 0 {
    last_tile_idx := decode_poly_id_tile(poly_path[len(poly_path)-1])
    last_poly_idx := decode_poly_id_poly(poly_path[len(poly_path)-1])
    if last_tile_idx < u32(navmesh.max_tiles) {
      last_tile := &navmesh.tiles[last_tile_idx]
      if last_tile.header != nil && last_poly_idx < u32(last_tile.header.poly_count) {
        last_poly := &last_tile.polys[last_poly_idx]
        clamped_end, _ = closest_point_on_poly(last_tile, last_poly, end_pos)
        log.debugf("Clamped end from [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f]", 
                  end_pos.x, end_pos.y, end_pos.z, clamped_end.x, clamped_end.y, clamped_end.z)
      }
    }
  }
  
  // Check if we can go straight from start to end
  if len(poly_path) == 2 {
    // Validate that the straight path doesn't exit the navigation mesh
    if can_go_straight(navmesh, poly_path[0], poly_path[1], clamped_start, clamped_end) {
      path := make([][3]f32, 2)
      path[0] = clamped_start
      path[1] = clamped_end
      return path
    }
  }
  
  log.debugf("string_pull_path: Processing polygon path:")
  for i, poly_ref in poly_path {
    if i < 5 {  // Debug first few polygons
      log.debugf("  Polygon %d: %x", i, poly_ref)
    }
  }
  
  // Run funnel algorithm
  path := make([dynamic][3]f32)
  append(&path, clamped_start)
  
  apex := clamped_start
  apex_idx := 0
  
  // Initialize funnel with start position
  left := clamped_start
  right := clamped_start
  left_idx := 0
  right_idx := 0
  
  log.debugf("string_pull: Starting funnel - apex: [%.2f,%.2f,%.2f], left: [%.2f,%.2f,%.2f], right: [%.2f,%.2f,%.2f]",
            apex.x, apex.y, apex.z, left.x, left.y, left.z, right.x, right.y, right.z)
  
  // Process portals starting from 0 (matching Detour's approach)
  i := 0
  max_string_pull_iterations := len(poly_path) * 10  // Safety limit based on polygon count
  string_pull_iterations := 0
  
  for i < len(poly_path) {
    string_pull_iterations += 1
    if string_pull_iterations > max_string_pull_iterations {
      log.errorf("string_pull_path: Infinite loop detected after %d iterations", string_pull_iterations)
      break
    }
    
    // Get the portal edges
    portal_left: [3]f32
    portal_right: [3]f32
    
    if i < len(poly_path) - 1 {
      // Regular portal between polygons
      // First try using the full portal edge (matching Detour)
      portal_left, portal_right = get_portal_points(navmesh, poly_path[i], poly_path[i+1])
      
      // Only constrain if the portal is extremely wide
      edge_length := linalg.distance(portal_left, portal_right)
      if edge_length > 10.0 {
        // For very large portals, use constrained version
        portal_left, portal_right = get_constrained_portal_points(navmesh, poly_path[i], poly_path[i+1], apex, clamped_end)
      }
    } else {
      // Last "portal" is the clamped end position
      portal_left = clamped_end
      portal_right = clamped_end
    }
    
    if i < 5 {  // Log first few portals
      log.infof("string_pull: Processing portal %d - left[%.2f,%.2f,%.2f], right[%.2f,%.2f,%.2f]", 
                i, portal_left.x, portal_left.y, portal_left.z, portal_right.x, portal_right.y, portal_right.z)
      log.infof("  Current funnel - apex[%.2f,%.2f,%.2f], left[%.2f,%.2f,%.2f], right[%.2f,%.2f,%.2f]",
                apex.x, apex.y, apex.z, left.x, left.y, left.z, right.x, right.y, right.z)
    }
    
    // Skip portal if we're starting very close to it (Detour does this)
    if i == 0 {
      // Check distance to portal line segment
      edge_dir := portal_right - portal_left
      edge_len_sq := linalg.dot(edge_dir, edge_dir)
      if edge_len_sq > 0.0001 {
        t := linalg.dot(apex - portal_left, edge_dir) / edge_len_sq
        t = max(0, min(1, t))
        closest_pt := portal_left + t * edge_dir
        dist := apex - closest_pt
        dist_sq := linalg.dot(dist, dist)
        if dist_sq < 0.001 * 0.001 {
          i += 1
          continue
        }
      }
    }
    
    // Update right vertex
    if tri_area_2d(apex, right, portal_right) <= 0 {
      if apex == right || tri_area_2d(apex, left, portal_right) > 0 {
        right = portal_right
        right_idx = i
        if i <= 3 {
          log.debugf("Funnel %d: Updated right to portal %d", i, i)
        }
      } else {
        // Tighten the funnel
        log.debugf("Funnel %d: Adding corner at left (tightening), left_idx=%d", i, left_idx)
        append(&path, left)
        
        // Move apex to the left vertex
        apex = left
        apex_idx = left_idx
        
        // Reset portal
        left = apex
        right = apex
        left_idx = apex_idx
        right_idx = apex_idx
        
        // Restart from apex (matching Detour's behavior)
        // Continue from the next portal after the apex to avoid reprocessing
        i = apex_idx + 1
        continue
      }
    }
    
    // Update left vertex  
    if tri_area_2d(apex, left, portal_left) >= 0 {
      if apex == left || tri_area_2d(apex, right, portal_left) < 0 {
        left = portal_left
        left_idx = i
        if i <= 3 {
          log.debugf("Funnel %d: Updated left to portal %d", i, i)
        }
      } else {
        // Tighten the funnel
        log.debugf("Funnel %d: Adding corner at right (tightening), right_idx=%d", i, right_idx)
        append(&path, right)
        
        // Move apex to the right vertex
        apex = right
        apex_idx = right_idx
        
        // Reset portal
        left = apex
        right = apex
        left_idx = apex_idx
        right_idx = apex_idx
        
        // Restart from apex (matching Detour's behavior)
        // Continue from the next portal after the apex to avoid reprocessing
        i = apex_idx + 1
        continue
      }
    }
    
    i += 1
  }
  
  // The loop should have processed all portals including the end position
  // Only add the end position if it wasn't already added
  if len(path) == 0 || path[len(path)-1] != clamped_end {
    append(&path, clamped_end)
  }
  
  // Post-process: validate path segments don't cut through obstacles
  validated_path := validate_and_fix_path(navmesh, path[:], poly_path)
  delete(path)
  
  return validated_path
}

// Get portal points between two adjacent polygons
get_portal_points :: proc(navmesh: ^NavMesh, poly_ref1, poly_ref2: PolyRef) -> (left, right: [3]f32) {
  // Get polygon data for poly1
  tile_idx1 := decode_poly_id_tile(poly_ref1)
  poly_idx1 := decode_poly_id_poly(poly_ref1)
  
  if tile_idx1 >= u32(navmesh.max_tiles) {
    return {}, {}
  }
  
  tile1 := &navmesh.tiles[tile_idx1]
  if tile1.header == nil || poly_idx1 >= u32(tile1.header.poly_count) {
    return {}, {}
  }
  
  poly1 := &tile1.polys[poly_idx1]
  
  // Find the link from poly1 to poly2
  edge_idx := -1
  link_side := u8(0xff)
  link_bmin := u8(0)
  link_bmax := u8(255)
  
  for link_idx := poly1.first_link; link_idx != NULL_LINK; {
    if link_idx >= u32(len(tile1.links)) do break
    link := &tile1.links[link_idx]
    
    if link.ref == poly_ref2 {
      edge_idx = int(link.edge)
      link_side = link.side
      link_bmin = link.bmin
      link_bmax = link.bmax
      break
    }
    
    link_idx = link.next
  }
  
  if edge_idx == -1 {
    log.warnf("get_portal_points: No link found from poly %x to poly %x", poly_ref1, poly_ref2)
    // No link found, return polygon centers as fallback
    center1 := get_poly_center(navmesh, poly_ref1)
    center2 := get_poly_center(navmesh, poly_ref2)
    return center1, center2
  }
  
  // Get the edge vertices
  v0_idx := poly1.verts[edge_idx]
  v1_idx := poly1.verts[(edge_idx + 1) % int(poly1.vert_count)]
  
  if v0_idx >= u16(tile1.header.vert_count) || v1_idx >= u16(tile1.header.vert_count) {
    log.warnf("get_portal_points: Invalid vertex indices %d, %d", v0_idx, v1_idx)
    center1 := get_poly_center(navmesh, poly_ref1)
    center2 := get_poly_center(navmesh, poly_ref2)
    return center1, center2
  }
  
  // Get vertex positions
  v0 := [3]f32{
    tile1.verts[v0_idx * 3 + 0],
    tile1.verts[v0_idx * 3 + 1],
    tile1.verts[v0_idx * 3 + 2],
  }
  v1 := [3]f32{
    tile1.verts[v1_idx * 3 + 0],
    tile1.verts[v1_idx * 3 + 1],
    tile1.verts[v1_idx * 3 + 2],
  }
  
  // In Detour, the portal vertices need to be ordered consistently
  // The vertices should form a "gate" that we're passing through
  // When moving from poly1 to poly2, we need to return the vertices
  // in an order that makes sense for the string pulling algorithm
  
  // Debug: Log the portal edge for analysis
  log.infof("get_portal_points: poly %x->%x, edge %d, v0[%.2f,%.2f,%.2f], v1[%.2f,%.2f,%.2f]", 
            poly_ref1, poly_ref2, edge_idx, v0.x, v0.y, v0.z, v1.x, v1.y, v1.z)
  
  // Check if we need to clamp the portal based on the link's bmin/bmax
  // This is important for tile boundaries and large polygons
  if link_side != 0xff {
    // This is a tile boundary edge, check if we need to clamp
    if link_bmin != 0 || link_bmax != 255 {
      s := f32(1.0 / 255.0)
      tmin := f32(link_bmin) * s
      tmax := f32(link_bmax) * s
      left := linalg.lerp(v0, v1, tmin)
      right := linalg.lerp(v0, v1, tmax)
      log.infof("  Clamped portal: tmin=%.2f, tmax=%.2f, left[%.2f,%.2f,%.2f], right[%.2f,%.2f,%.2f]",
                tmin, tmax, left.x, left.y, left.z, right.x, right.y, right.z)
      return left, right
    }
  }
  
  // For internal edges, we should still limit the portal size to something reasonable
  // Let's find the actual shared portion of the edge with poly2
  // For now, return the full edge but log a warning if it's very long
  edge_length := linalg.distance(v0, v1)
  if edge_length > 5.0 {
    log.warnf("  Large portal edge: length %.2f", edge_length)
  }
  
  // The edge vertices in a polygon are ordered counter-clockwise
  // When traversing from poly1 to poly2, we need the vertices in consistent order
  // The funnel algorithm expects (left, right) vertices when looking from poly1 to poly2
  // Since polygon vertices are CCW, v0 is left and v1 is right when exiting the edge
  return v0, v1
}

// Get edge midpoint between two adjacent polygons (for better pathfinding accuracy)
get_edge_midpoint :: proc(navmesh: ^NavMesh, poly_ref1, poly_ref2: PolyRef) -> [3]f32 {
  // Get portal points between the polygons
  left, right := get_portal_points(navmesh, poly_ref1, poly_ref2)
  
  // Return midpoint of the shared edge
  return (left + right) * 0.5
}

// Calculate 2D triangle area (for funnel algorithm)
tri_area_2d :: proc(a, b, c: [3]f32) -> f32 {
  return (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
}

// Check if we can go straight between two adjacent polygons
can_go_straight :: proc(navmesh: ^NavMesh, poly_ref1, poly_ref2: PolyRef, start_pos, end_pos: [3]f32) -> bool {
  // Get the shared edge between the two polygons
  left, right := get_portal_points(navmesh, poly_ref1, poly_ref2)
  
  // Check if the straight line from start to end crosses through the portal
  // Using 2D projection (ignoring Y)
  t1 := tri_area_2d(start_pos, end_pos, left)
  t2 := tri_area_2d(start_pos, end_pos, right)
  
  // If signs are different, the line crosses between the portal points
  // If both are on the same side, the straight path would exit the mesh
  return t1 * t2 <= 0
}

// Validate path segments and fix any that cut through obstacles
validate_and_fix_path :: proc(navmesh: ^NavMesh, path: [][3]f32, poly_path: []PolyRef) -> [][3]f32 {
  if len(path) <= 2 do return path
  
  validated := make([dynamic][3]f32)
  append(&validated, path[0])
  
  for i in 1..<len(path) {
    start_point := validated[len(validated)-1]
    end_point := path[i]
    
    // Check if this segment might cut through an obstacle
    // For now, detect potentially problematic segments based on distance and direction
    segment_length := linalg.distance(start_point, end_point)
    
    // If segment is very long and changes direction significantly, it might be cutting through
    if segment_length > 5.0 && i < len(path) - 1 {
      // Add intermediate waypoints from the polygon path to ensure we go around obstacles
      // Find which polygons this segment should traverse
      start_poly_idx := find_polygon_in_path(navmesh, poly_path, start_point)
      end_poly_idx := find_polygon_in_path(navmesh, poly_path, end_point)
      
      if start_poly_idx >= 0 && end_poly_idx >= 0 && end_poly_idx - start_poly_idx > 1 {
        // Add intermediate waypoints for long segments
        for j in start_poly_idx + 1..<end_poly_idx {
          if j < len(poly_path) {
            intermediate := get_poly_center(navmesh, poly_path[j])
            // Project to ground level
            intermediate.y = start_point.y
            append(&validated, intermediate)
          }
        }
      }
    }
    
    append(&validated, end_point)
  }
  
  return validated[:]
}

// Find which polygon in the path contains or is nearest to a point
find_polygon_in_path :: proc(navmesh: ^NavMesh, poly_path: []PolyRef, pos: [3]f32) -> int {
  best_idx := -1
  best_dist := f32(math.F32_MAX)
  
  for poly_ref, idx in poly_path {
    center := get_poly_center(navmesh, poly_ref)
    dist := linalg.distance(pos, center)
    if dist < best_dist {
      best_dist = dist
      best_idx = idx
    }
  }
  
  return best_idx
}