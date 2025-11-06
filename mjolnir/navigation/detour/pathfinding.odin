package navigation_detour

import "../recast"
import "core:container/priority_queue"
import "core:math"
import "core:math/linalg"
import "core:mem/virtual"

H_SCALE :: 0.999

// A* node with position, cost, and parent info
Node :: struct {
  pos:       [3]f32,
  cost:      f32,
  total:     f32,
  id:        recast.Poly_Ref,
  flags:     Node_Flags,
  parent_id: recast.Poly_Ref,
}

// Queue node for priority queue (minimal data)
Pathfinding_Node :: struct {
  ref:   recast.Poly_Ref,
  cost:  f32,
  total: f32,
}

Node_Flag :: enum u8 {
  Open            = 0,
  Closed          = 1,
  Parent_Detached = 2,
}
Node_Flags :: bit_set[Node_Flag;u8]

// Arena-based pathfinding context
Pathfinding_Context :: struct {
  nodes: map[recast.Poly_Ref]^Node,
  arena: virtual.Arena,
}

Node_Queue :: struct {
  heap: priority_queue.Priority_Queue(Pathfinding_Node),
}

// Initialize pathfinding context
pathfinding_context_init :: proc(
  ctx: ^Pathfinding_Context,
  max_nodes: i32,
) -> recast.Status {
  if err := virtual.arena_init_growing(&ctx.arena); err != .None {
    return {.Out_Of_Memory}
  }
  ctx.nodes = make(map[recast.Poly_Ref]^Node, max_nodes)
  return {.Success}
}

pathfinding_context_clear :: proc(ctx: ^Pathfinding_Context) {
  clear(&ctx.nodes)
  free_all(virtual.arena_allocator(&ctx.arena))
}

pathfinding_context_destroy :: proc(ctx: ^Pathfinding_Context) {
  delete(ctx.nodes)
  virtual.arena_destroy(&ctx.arena)
  ctx^ = {}
}

get_node :: proc(ctx: ^Pathfinding_Context, id: recast.Poly_Ref) -> ^Node {
  if node, exists := ctx.nodes[id]; exists do return node
  return nil
}

create_node :: proc(ctx: ^Pathfinding_Context, id: recast.Poly_Ref) -> ^Node {
  if existing, ok := ctx.nodes[id]; ok do return existing
  node_mem, err := virtual.arena_alloc(
    &ctx.arena,
    size_of(Node),
    align_of(Node),
  )
  if err != .None do return nil
  node := cast(^Node)raw_data(node_mem)
  node.id = id
  node.flags = {}
  node.cost = 0
  node.total = 0
  node.parent_id = recast.INVALID_POLY_REF
  ctx.nodes[id] = node
  return node
}

// Priority queue comparison (min-heap for A*)
pathfinding_node_compare :: proc(a, b: Pathfinding_Node) -> bool {
  return a.total < b.total
}

// Node queue operations
node_queue_init :: proc(queue: ^Node_Queue, capacity: i32) -> recast.Status {
  queue.heap = priority_queue.Priority_Queue(Pathfinding_Node){}
  priority_queue.init(
    &queue.heap,
    pathfinding_node_compare,
    priority_queue.default_swap_proc(Pathfinding_Node),
    int(capacity),
  )
  return {.Success}
}

node_queue_clear :: proc(queue: ^Node_Queue) {
  priority_queue.clear(&queue.heap)
}

node_queue_destroy :: proc(queue: ^Node_Queue) {
  priority_queue.destroy(&queue.heap)
  queue^ = {}
}

node_queue_push :: proc(queue: ^Node_Queue, node: Pathfinding_Node) {
  priority_queue.push(&queue.heap, node)
}

node_queue_pop :: proc(queue: ^Node_Queue) -> Pathfinding_Node {
  if priority_queue.len(queue.heap) == 0 do return {recast.INVALID_POLY_REF, 0, 0}
  return priority_queue.pop(&queue.heap)
}

node_queue_empty :: proc(queue: ^Node_Queue) -> bool {
  return priority_queue.len(queue.heap) == 0
}

// Navigation mesh query system
Nav_Mesh_Query :: struct {
  nav_mesh:   ^Nav_Mesh,
  pf_context: Pathfinding_Context,
  open_list:  Node_Queue,
  query_data: Query_Data,
}

Query_Data :: struct {
  status:                recast.Status,
  last_best:             ^Node,
  start_ref:             recast.Poly_Ref,
  end_ref:               recast.Poly_Ref,
  start_pos:             [3]f32,
  end_pos:               [3]f32,
  filter:                ^Query_Filter,
  options:               u32,
  raycast_limit_squared: f32,
}

nav_mesh_query_init :: proc(
  query: ^Nav_Mesh_Query,
  nav_mesh: ^Nav_Mesh,
  max_nodes: i32,
) -> recast.Status {
  query.nav_mesh = nav_mesh
  status := pathfinding_context_init(&query.pf_context, max_nodes)
  if recast.status_failed(status) do return status
  status = node_queue_init(&query.open_list, max_nodes)
  if recast.status_failed(status) {
    pathfinding_context_destroy(&query.pf_context)
    return status
  }
  return {.Success}
}

nav_mesh_query_destroy :: proc(query: ^Nav_Mesh_Query) {
  node_queue_destroy(&query.open_list)
  pathfinding_context_destroy(&query.pf_context)
  query^ = {}
}

// A* pathfinding algorithm
find_path :: proc(
  query: ^Nav_Mesh_Query,
  start_ref, end_ref: recast.Poly_Ref,
  start_pos, end_pos: [3]f32,
  filter: ^Query_Filter,
  path: []recast.Poly_Ref,
  max_path: i32,
) -> (
  status: recast.Status,
  path_count: i32,
) {
  path_count = 0
  if !is_valid_poly_ref(query.nav_mesh, start_ref) ||
     !is_valid_poly_ref(query.nav_mesh, end_ref) {
    return {.Invalid_Param}, 0
  }
  if start_ref == end_ref {
    if max_path > 0 {
      path[0] = start_ref
      return {.Success}, 1
    }
    return {.Buffer_Too_Small}, 0
  }
  // Initialize search
  pathfinding_context_clear(&query.pf_context)
  node_queue_clear(&query.open_list)
  start_node := create_node(&query.pf_context, start_ref)
  if start_node == nil do return {.Out_Of_Nodes}, 0
  start_node.pos = start_pos
  start_node.cost = 0
  start_node.total = linalg.distance(start_pos, end_pos) * H_SCALE
  start_node.flags = {.Open}
  start_node.parent_id = recast.INVALID_POLY_REF
  node_queue_push(
    &query.open_list,
    {start_ref, start_node.cost, start_node.total},
  )
  best_node := start_node
  best_dist := start_node.total
  iterations := 0
  // A* search loop
  for !node_queue_empty(&query.open_list) && iterations < 1000 {
    iterations += 1
    best_pathfinding_node := node_queue_pop(&query.open_list)
    if best_pathfinding_node.ref == recast.INVALID_POLY_REF do break
    current := get_node(&query.pf_context, best_pathfinding_node.ref)
    if current == nil || .Closed in current.flags do continue
    // Skip stale entries
    if best_pathfinding_node.total != current.total do continue
    current.flags &= ~{.Open}
    current.flags |= {.Closed}
    // Goal reached?
    if current.id == end_ref {
      best_node = current
      break
    }
    // Expand neighbors
    cur_tile, cur_poly, tile_status := get_tile_and_poly_by_ref(
      query.nav_mesh,
      current.id,
    )
    if recast.status_failed(tile_status) do continue
    // Iterate through polygon links
    link := cur_poly.first_link
    for link != recast.DT_NULL_LINK {
      neighbor_ref := get_link_poly_ref(cur_tile, link)
      if neighbor_ref != recast.INVALID_POLY_REF &&
         neighbor_ref != current.parent_id {
        neighbor_tile, neighbor_poly, neighbor_status :=
          get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
        if recast.status_succeeded(neighbor_status) &&
           query_filter_pass_filter(
             filter,
             neighbor_ref,
             neighbor_tile,
             neighbor_poly,
           ) {
          neighbor_node := get_node(&query.pf_context, neighbor_ref)
          // Calculate neighbor position
          neighbor_pos: [3]f32
          if neighbor_node == nil {
            left, right, _, portal_status := get_portal_points(
              query,
              current.id,
              neighbor_ref,
            )
            if recast.status_succeeded(portal_status) {
              neighbor_pos = linalg.mix(left, right, 0.5)
            } else {
              link_edge := get_link_edge(cur_tile, link)
              neighbor_pos = get_edge_mid_point(
                cur_tile,
                neighbor_tile,
                cur_poly,
                neighbor_poly,
                link_edge,
              )
            }
          } else {
            neighbor_pos = neighbor_node.pos
          }
          // Calculate costs
          cost: f32
          heuristic: f32
          if neighbor_ref == end_ref {
            // Special case for goal
            cur_cost := query_filter_get_cost(
              filter,
              current.pos,
              neighbor_pos,
              current.parent_id,
              nil,
              nil,
              current.id,
              cur_tile,
              cur_poly,
              neighbor_ref,
              neighbor_tile,
              neighbor_poly,
            )
            end_cost := query_filter_get_cost(
              filter,
              neighbor_pos,
              end_pos,
              current.id,
              cur_tile,
              cur_poly,
              neighbor_ref,
              neighbor_tile,
              neighbor_poly,
              recast.INVALID_POLY_REF,
              nil,
              nil,
            )
            cost = current.cost + cur_cost + end_cost
            heuristic = 0
          } else {
            cost =
              current.cost +
              query_filter_get_cost(
                filter,
                current.pos,
                neighbor_pos,
                current.parent_id,
                nil,
                nil,
                current.id,
                cur_tile,
                cur_poly,
                neighbor_ref,
                neighbor_tile,
                neighbor_poly,
              )
            heuristic = linalg.distance(neighbor_pos, end_pos) * H_SCALE
          }
          total := cost + heuristic
          // Skip if worse than existing
          if neighbor_node != nil &&
             .Open in neighbor_node.flags &&
             total >= neighbor_node.total {
            link = get_next_link(cur_tile, link)
            continue
          }
          if neighbor_node != nil &&
             .Closed in neighbor_node.flags &&
             total >= neighbor_node.total {
            link = get_next_link(cur_tile, link)
            continue
          }
          // Create or update node
          if neighbor_node == nil {
            neighbor_node = create_node(&query.pf_context, neighbor_ref)
            if neighbor_node == nil do break
            neighbor_node.pos = neighbor_pos
          }
          if .Closed in neighbor_node.flags {
            neighbor_node.flags &= ~{.Closed}
          }
          neighbor_node.id = neighbor_ref
          neighbor_node.parent_id = current.id
          neighbor_node.cost = cost
          neighbor_node.total = total
          neighbor_node.flags |= {.Open}
          node_queue_push(
            &query.open_list,
            {neighbor_ref, neighbor_node.cost, neighbor_node.total},
          )
          // Update best node if closer to goal
          if heuristic < best_dist {
            best_dist = heuristic
            best_node = neighbor_node
          }
        }
      }
      link = get_next_link(cur_tile, link)
    }
  }
  if best_node == nil do return {.Invalid_Param}, 0
  return get_path_to_node(query, best_node, path, max_path)
}

// Reconstruct path from end node back to start
get_path_to_node :: proc(
  query: ^Nav_Mesh_Query,
  end_node: ^Node,
  path: []recast.Poly_Ref,
  max_path: i32,
) -> (
  status: recast.Status,
  path_count: i32,
) {
  // Count path length
  node := end_node
  length := i32(0)
  for node != nil {
    length += 1
    if node.parent_id == recast.INVALID_POLY_REF do break
    node = get_node(&query.pf_context, node.parent_id)
  }
  if length > max_path do return {.Buffer_Too_Small}, 0
  // Build path in reverse
  node = end_node
  for i := length - 1; i >= 0; i -= 1 {
    path[i] = node.id
    if node.parent_id == recast.INVALID_POLY_REF do break
    node = get_node(&query.pf_context, node.parent_id)
  }
  return {.Success}, length
}

// Link traversal helpers
get_first_link :: proc(tile: ^Mesh_Tile, poly: i32) -> u32 {
  if poly < 0 || poly >= i32(len(tile.polys)) do return recast.DT_NULL_LINK
  return tile.polys[poly].first_link
}

get_next_link :: proc(tile: ^Mesh_Tile, link: u32) -> u32 {
  if link == recast.DT_NULL_LINK || int(link) >= len(tile.links) do return recast.DT_NULL_LINK
  return tile.links[link].next
}

get_link_poly_ref :: proc(tile: ^Mesh_Tile, link: u32) -> recast.Poly_Ref {
  if link == recast.DT_NULL_LINK || int(link) >= len(tile.links) do return recast.INVALID_POLY_REF
  return tile.links[link].ref
}

get_link_edge :: proc(tile: ^Mesh_Tile, link: u32) -> u8 {
  if link == recast.DT_NULL_LINK || int(link) >= len(tile.links) do return 0xff
  return tile.links[link].edge
}

get_edge_mid_point :: proc(
  tile_a, tile_b: ^Mesh_Tile,
  poly_a, poly_b: ^Poly,
  edge: u8,
) -> [3]f32 {
  va0 := tile_a.verts[poly_a.verts[edge]]
  va1 := tile_a.verts[poly_a.verts[(edge + 1) % poly_a.vert_count]]
  return linalg.mix(va0, va1, 0.5)
}

// Sliced pathfinding for large searches
init_sliced_find_path :: proc(
  query: ^Nav_Mesh_Query,
  start_ref: recast.Poly_Ref,
  end_ref: recast.Poly_Ref,
  start_pos: [3]f32,
  end_pos: [3]f32,
  filter: ^Query_Filter,
  options: u32,
) -> recast.Status {
  if !is_valid_poly_ref(query.nav_mesh, start_ref) ||
     !is_valid_poly_ref(query.nav_mesh, end_ref) {
    return {.Invalid_Param}
  }
  query.query_data.status = {.In_Progress}
  query.query_data.start_ref = start_ref
  query.query_data.end_ref = end_ref
  query.query_data.start_pos = start_pos
  query.query_data.end_pos = end_pos
  query.query_data.filter = filter
  query.query_data.options = options
  query.query_data.raycast_limit_squared = math.F32_MAX
  pathfinding_context_clear(&query.pf_context)
  node_queue_clear(&query.open_list)
  start_node := create_node(&query.pf_context, start_ref)
  if start_node == nil do return {.Out_Of_Nodes}
  start_node.pos = start_pos
  start_node.cost = 0
  start_node.total = linalg.distance(start_pos, end_pos) * H_SCALE
  start_node.flags = {.Open}
  start_node.parent_id = recast.INVALID_POLY_REF
  node_queue_push(
    &query.open_list,
    {start_ref, start_node.cost, start_node.total},
  )
  query.query_data.last_best = start_node
  return {.Success}
}

update_sliced_find_path :: proc(
  query: ^Nav_Mesh_Query,
  max_iter: i32,
) -> (
  done_iters: i32,
  status: recast.Status,
) {
  if query.query_data.status != {.In_Progress} do return 0, query.query_data.status
  iterations := i32(0)
  for !node_queue_empty(&query.open_list) && iterations < max_iter {
    iterations += 1
    best := node_queue_pop(&query.open_list)
    if best.ref == recast.INVALID_POLY_REF do break
    current := get_node(&query.pf_context, best.ref)
    if current == nil || .Closed in current.flags do continue
    current.flags |= {.Closed}
    current.flags &= ~{.Open}
    if current.total < query.query_data.last_best.total {
      query.query_data.last_best = current
    }
    if current.id == query.query_data.end_ref {
      query.query_data.last_best = current
      query.query_data.status = {.Success}
      return iterations, query.query_data.status
    }
    // Expand neighbors (simplified version)
    cur_tile, cur_poly, tile_status := get_tile_and_poly_by_ref(
      query.nav_mesh,
      current.id,
    )
    if recast.status_failed(tile_status) do continue
    link := cur_poly.first_link
    for link != recast.DT_NULL_LINK {
      neighbor_ref := get_link_poly_ref(cur_tile, link)
      if neighbor_ref != recast.INVALID_POLY_REF &&
         neighbor_ref != current.parent_id {
        neighbor_tile, neighbor_poly, neighbor_status :=
          get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
        if recast.status_succeeded(neighbor_status) &&
           query_filter_pass_filter(
             query.query_data.filter,
             neighbor_ref,
             neighbor_tile,
             neighbor_poly,
           ) {
          neighbor_node := get_node(&query.pf_context, neighbor_ref)
          neighbor_pos: [3]f32
          if neighbor_node == nil {
            neighbor_pos = calc_poly_center(neighbor_tile, neighbor_poly)
          } else {
            neighbor_pos = neighbor_node.pos
          }
          cost :=
            current.cost +
            query_filter_get_cost(
              query.query_data.filter,
              current.pos,
              neighbor_pos,
              current.parent_id,
              nil,
              nil,
              current.id,
              cur_tile,
              cur_poly,
              neighbor_ref,
              neighbor_tile,
              neighbor_poly,
            )
          heuristic :=
            linalg.distance(neighbor_pos, query.query_data.end_pos) * H_SCALE
          total := cost + heuristic
          if neighbor_node != nil &&
             .Open in neighbor_node.flags &&
             total >= neighbor_node.total {
            link = get_next_link(cur_tile, link)
            continue
          }
          if neighbor_node != nil &&
             .Closed in neighbor_node.flags &&
             total >= neighbor_node.total {
            link = get_next_link(cur_tile, link)
            continue
          }
          if neighbor_node == nil {
            neighbor_node = create_node(&query.pf_context, neighbor_ref)
            if neighbor_node == nil do break
            neighbor_node.pos = neighbor_pos
          }
          if .Closed in neighbor_node.flags {
            neighbor_node.flags &= ~{.Closed}
          }
          neighbor_node.id = neighbor_ref
          neighbor_node.parent_id = current.id
          neighbor_node.cost = cost
          neighbor_node.total = total
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
  if node_queue_empty(&query.open_list) {
    query.query_data.status = {.Success}
  }
  return iterations, query.query_data.status
}

finalize_sliced_find_path :: proc(
  query: ^Nav_Mesh_Query,
  path: []recast.Poly_Ref,
  max_path: i32,
) -> (
  status: recast.Status,
  path_count: i32,
) {
  if query.query_data.status != {.Success} do return query.query_data.status, 0
  if query.query_data.last_best == nil do return {.Invalid_Param}, 0
  return get_path_to_node(query, query.query_data.last_best, path, max_path)
}

finalize_sliced_find_path_partial :: proc(
  query: ^Nav_Mesh_Query,
  existing: []recast.Poly_Ref,
  path: []recast.Poly_Ref,
  max_path: i32,
) -> (
  status: recast.Status,
  path_count: i32,
) {
  if query.query_data.last_best == nil do return {.Invalid_Param}, 0
  return get_path_to_node(query, query.query_data.last_best, path, max_path)
}

// Convenience function for complete sliced pathfinding
find_path_sliced :: proc(
  query: ^Nav_Mesh_Query,
  start_ref: recast.Poly_Ref,
  end_ref: recast.Poly_Ref,
  start_pos: [3]f32,
  end_pos: [3]f32,
  filter: ^Query_Filter,
  path: []recast.Poly_Ref,
  max_path: i32,
  max_iterations_per_slice: i32 = 50,
) -> (
  status: recast.Status,
  path_count: i32,
) {
  init_status := init_sliced_find_path(
    query,
    start_ref,
    end_ref,
    start_pos,
    end_pos,
    filter,
    0,
  )
  if recast.status_failed(init_status) do return init_status, 0
  iter_count := 0
  for iter_count < 10000 {
    done_iters, update_status := update_sliced_find_path(
      query,
      max_iterations_per_slice,
    )
    iter_count += int(done_iters)
    if update_status != {.In_Progress} do return finalize_sliced_find_path(query, path, max_path)
  }
  return {.Out_Of_Nodes}, 0
}
