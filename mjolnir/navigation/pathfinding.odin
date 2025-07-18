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
  
  // Convert polygon path to world positions using string pulling
  log.info("find_path: Starting string pulling...")
  path := string_pull_path(query.mesh, poly_path, start_pos, end_pos)
  log.infof("find_path: String pulling completed, path has %d points", len(path))
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

// Find closest point on polygon (simplified)
closest_point_on_poly :: proc(tile: ^MeshTile, poly: ^Poly, pos: [3]f32) -> ([3]f32, f32) {
  if poly.vert_count < 3 do return pos, math.F32_MAX
  
  // Simple implementation: find closest point to polygon center
  // This could be improved with proper point-in-polygon tests and edge projection
  center := [3]f32{0, 0, 0}
  valid_verts := 0
  
  for i in 0..<poly.vert_count {
    vert_idx := poly.verts[i]
    if vert_idx >= u16(tile.header.vert_count) do continue
    
    vert_pos := [3]f32{
      tile.verts[vert_idx * 3 + 0],
      tile.verts[vert_idx * 3 + 1],
      tile.verts[vert_idx * 3 + 2],
    }
    
    center += vert_pos
    valid_verts += 1
  }
  
  if valid_verts == 0 do return pos, math.F32_MAX
  
  center /= f32(valid_verts)
  
  // Project query point to polygon's Y level
  closest := [3]f32{pos.x, center.y, pos.z}
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
    h_cost = linalg.distance(start_pos, end_pos),
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
    
    if iterations <= 5 {  // Debug first few iterations
      log.debugf("A* iter %d: current poly=%x, f_cost=%.2f, g_cost=%.2f, h_cost=%.2f", 
                 iterations, current.poly_ref, current.f_cost, current.g_cost, current.h_cost)
    }
    
    // Check if we reached the goal
    if current.poly_ref == end_ref {
      log.infof("A* found path after %d iterations!", iterations)
      best_node = current
      break
    }
    
    // Update best node if this one is closer to goal
    if current.h_cost < best_node.h_cost {
      best_node = current
    }
    
    // Expand neighbors
    expand_neighbors(query, current, end_ref, end_pos)
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
expand_neighbors :: proc(query: ^PathQuery, current: PathNode, end_ref: PolyRef, end_pos: [3]f32) {
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
    
    if neighbor_count < 3 {  // Debug first few neighbors of each polygon
      log.debugf("  Link %d: neighbor_ref=%x, edge=%d, parent=%x", link_idx, neighbor_ref, link.edge, current.parent)
    }
    
    if neighbor_ref == 0 {
      log.debugf("  Skipping null neighbor reference")
      continue
    }
    if neighbor_ref == current.parent {
      log.debugf("  Skipping parent polygon %x", neighbor_ref)
      continue
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
    
    // Calculate neighbor position (simplified - use polygon center)
    neighbor_pos := get_poly_center(query.mesh, neighbor_ref)
    
    // Calculate costs
    move_cost := linalg.distance(current.position, neighbor_pos)
    new_g_cost := current.g_cost + move_cost
    new_h_cost := linalg.distance(neighbor_pos, end_pos)
    new_f_cost := new_g_cost + new_h_cost
    
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
  
  // Get portal edges between polygons
  portals := make([][6]f32, len(poly_path) + 1)
  defer delete(portals)
  
  // First portal is from start position
  portals[0] = [6]f32{start_pos.x, start_pos.y, start_pos.z, 
                      start_pos.x, start_pos.y, start_pos.z}
  
  portal_count := 0
  for i in 0..<len(poly_path) - 1 {
    portal_left, portal_right := get_portal_points(navmesh, poly_path[i], poly_path[i+1])
    portals[i+1] = [6]f32{portal_left.x, portal_left.y, portal_left.z, 
                          portal_right.x, portal_right.y, portal_right.z}
    
    // Check if we got valid portal points
    if portal_left == portal_right {
      log.warnf("string_pull_path: Portal %d has identical left/right points (likely no shared edge found)", i)
    } else {
      portal_count += 1
    }
  }
  
  // Last portal is to end position
  portals[len(poly_path)] = [6]f32{end_pos.x, end_pos.y, end_pos.z, 
                                    end_pos.x, end_pos.y, end_pos.z}
  
  log.debugf("string_pull_path: Found %d valid portals out of %d polygon transitions", portal_count, len(poly_path) - 1)
  
  // Run funnel algorithm
  path := make([dynamic][3]f32)
  append(&path, start_pos)
  
  apex := start_pos
  apex_idx := 0
  
  left := [3]f32{portals[0][0], portals[0][1], portals[0][2]}
  right := [3]f32{portals[0][3], portals[0][4], portals[0][5]}
  left_idx := 0
  right_idx := 0
  
  log.debugf("string_pull: Starting funnel - apex: [%.2f,%.2f,%.2f], left: [%.2f,%.2f,%.2f], right: [%.2f,%.2f,%.2f]",
            apex.x, apex.y, apex.z, left.x, left.y, left.z, right.x, right.y, right.z)
  
  i := 1
  max_string_pull_iterations := len(portals) * 10  // Safety limit
  string_pull_iterations := 0
  
  for i < len(portals) {
    string_pull_iterations += 1
    if string_pull_iterations > max_string_pull_iterations {
      log.errorf("string_pull_path: Infinite loop detected after %d iterations", string_pull_iterations)
      break
    }
    portal_left := [3]f32{portals[i][0], portals[i][1], portals[i][2]}
    portal_right := [3]f32{portals[i][3], portals[i][4], portals[i][5]}
    
    // Update right vertex
    if tri_area_2d(apex, right, portal_right) <= 0 {
      if apex == right || tri_area_2d(apex, left, portal_right) > 0 {
        right = portal_right
        right_idx = i
      } else {
        // Tighten the funnel
        append(&path, left)
        
        // Move apex to the left vertex
        apex = left
        apex_idx = left_idx
        
        // Reset portal
        left = apex
        right = apex
        left_idx = apex_idx
        right_idx = apex_idx
        
        // Restart from the next portal after apex
        i = apex_idx + 1
        continue
      }
    }
    
    // Update left vertex  
    if tri_area_2d(apex, left, portal_left) >= 0 {
      if apex == left || tri_area_2d(apex, right, portal_left) < 0 {
        left = portal_left
        left_idx = i
      } else {
        // Tighten the funnel
        append(&path, right)
        
        // Move apex to the right vertex
        apex = right
        apex_idx = right_idx
        
        // Reset portal
        left = apex
        right = apex
        left_idx = apex_idx
        right_idx = apex_idx
        
        // Restart from the next portal after apex
        i = apex_idx + 1
        continue
      }
    }
    
    i += 1
  }
  
  // The final portal to end_pos was already processed in the loop
  // Just add the final destination if not already added
  if len(path) == 0 || path[len(path)-1] != end_pos {
    append(&path, end_pos)
  }
  
  return path[:]
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
  for link_idx := poly1.first_link; link_idx != NULL_LINK; {
    if link_idx >= u32(len(tile1.links)) do break
    link := &tile1.links[link_idx]
    
    if link.ref == poly_ref2 {
      edge_idx = int(link.edge)
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
  
  // IMPORTANT: Order vertices as left/right based on traversal direction
  // We need to determine which vertex is "left" and which is "right"
  // when moving from poly1 to poly2
  
  // Get the centers of both polygons to determine traversal direction
  center1 := get_poly_center(navmesh, poly_ref1)
  center2 := get_poly_center(navmesh, poly_ref2)
  
  // Calculate the direction vector from poly1 to poly2
  dir := [3]f32{
    center2.x - center1.x,
    center2.y - center1.y,
    center2.z - center1.z,
  }
  
  // Calculate which vertex is on the left side of the traversal direction
  // Using cross product in XZ plane (Y-up coordinate system)
  edge_dir := [3]f32{v1.x - v0.x, 0, v1.z - v0.z}
  cross := dir.x * edge_dir.z - dir.z * edge_dir.x
  
  // If cross product is positive, v0 is on the left, v1 on the right
  // Otherwise, swap them
  if cross > 0 {
    return v0, v1
  } else {
    return v1, v0
  }
}


// Calculate 2D triangle area (for funnel algorithm)
tri_area_2d :: proc(a, b, c: [3]f32) -> f32 {
  return (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
}