package navigation_detour

import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:container/priority_queue"
import "core:slice"
import "core:log"
import nav_recast "../recast"

// Heuristic scale factor for A* pathfinding
// Slightly less than 1.0 to keep the heuristic admissible and guarantee optimal paths
// Matching C++ implementation's value for consistent behavior
H_SCALE :: 0.999

// A* pathfinding node (full data)
Node :: struct {
    pos:       [3]f32,             // Node position
    cost:      f32,                // Cost from start to this node
    total:     f32,                // Cost + heuristic
    id:        nav_recast.Poly_Ref,  // Polygon reference
    flags:     Node_Flags,      // Node state flags
    parent_id: nav_recast.Poly_Ref,  // Parent node reference
}

// Self-contained pathfinding queue element (no external context needed)
Pathfinding_Node :: struct {
    ref:   nav_recast.Poly_Ref,  // Polygon reference
    cost:  f32,                // Cost from start to this node
    total: f32,                // Cost + heuristic (f-score)
}

// Node flags
Node_Flag :: enum u8 {
    Open   = 0,
    Closed = 1,
    Parent_Detached = 2,
}

Node_Flags :: bit_set[Node_Flag; u8]

// Node pool for A* pathfinding
Node_Pool :: struct {
    nodes:     map[nav_recast.Poly_Ref]Node,  // Hash map for fast lookup
    node_pool: []Node,                      // Pre-allocated node storage
    next_free: i32,                            // Next available node index
    max_nodes: i32,                            // Maximum number of nodes
}

// Node queue for A* open list (self-contained)
Node_Queue :: struct {
    heap: priority_queue.Priority_Queue(Pathfinding_Node),
    nodes: ^Node_Pool,  // Still needed for full node data
}

// Initialize node pool
node_pool_init :: proc(pool: ^Node_Pool, max_nodes: i32) -> nav_recast.Status {
    pool.max_nodes = max_nodes
    pool.nodes = make(map[nav_recast.Poly_Ref]Node, max_nodes)
    pool.node_pool = make([]Node, max_nodes)
    pool.next_free = 0
    return {.Success}
}

// Clear node pool
node_pool_clear :: proc(pool: ^Node_Pool) {
    clear(&pool.nodes)
    pool.next_free = 0
}

// Destroy node pool
node_pool_destroy :: proc(pool: ^Node_Pool) {
    delete(pool.nodes)
    delete(pool.node_pool)
    pool^ = {}
}

// Get node from pool
node_pool_get_node :: proc(pool: ^Node_Pool, id: nav_recast.Poly_Ref) -> ^Node {
    if node, exists := &pool.nodes[id]; exists {
        return node
    }
    return nil
}

// Create new node in pool
node_pool_create_node :: proc(pool: ^Node_Pool, id: nav_recast.Poly_Ref) -> ^Node {
    if pool.next_free >= pool.max_nodes {
        return nil
    }

    node := &pool.node_pool[pool.next_free]
    pool.next_free += 1

    node.id = id
    node.flags = {}
    node.cost = 0
    node.total = 0
    node.parent_id = nav_recast.INVALID_POLY_REF

    pool.nodes[id] = node^
    return &pool.nodes[id]
}


// Self-contained comparison function for pathfinding nodes
// Returns true if 'a' has higher priority than 'b' (should come first)
// For A* pathfinding, lower total cost = higher priority (min-heap behavior)
pathfinding_node_compare :: proc(a, b: Pathfinding_Node) -> bool {
    // For min-heap: return true if 'a' should come before 'b'
    // We want lower costs to have higher priority (come first)
    // Just use total cost for comparison (matching C++ implementation)
    return a.total < b.total
}

node_queue_init :: proc(queue: ^Node_Queue, nodes: ^Node_Pool, capacity: i32) -> nav_recast.Status {
    queue.nodes = nodes

    // Initialize priority queue with self-contained comparison function
    queue.heap = priority_queue.Priority_Queue(Pathfinding_Node){}

    priority_queue.init(&queue.heap,
                        pathfinding_node_compare,
                        priority_queue.default_swap_proc(Pathfinding_Node),
                        int(capacity))

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
    if priority_queue.len(queue.heap) == 0 {
        return {nav_recast.INVALID_POLY_REF, 0, 0}
    }

    return priority_queue.pop(&queue.heap)
}

node_queue_empty :: proc(queue: ^Node_Queue) -> bool {
    return priority_queue.len(queue.heap) == 0
}

// Navigation mesh query system
Nav_Mesh_Query :: struct {
    nav_mesh:   ^Nav_Mesh,
    node_pool:  Node_Pool,
    open_list:  Node_Queue,
    query_data: Query_Data,
}

// Query working data
Query_Data :: struct {
    status:      nav_recast.Status,
    last_best:   ^Node,
    start_ref:   nav_recast.Poly_Ref,
    end_ref:     nav_recast.Poly_Ref,
    start_pos:   [3]f32,
    end_pos:     [3]f32,
    filter:      ^Query_Filter,
    options:     u32,
    raycast_limit_squared: f32,
}

// Initialize query object
nav_mesh_query_init :: proc(query: ^Nav_Mesh_Query, nav_mesh: ^Nav_Mesh, max_nodes: i32) -> nav_recast.Status {
    query.nav_mesh = nav_mesh

    status := node_pool_init(&query.node_pool, max_nodes)
    if nav_recast.status_failed(status) {
        return status
    }

    status = node_queue_init(&query.open_list, &query.node_pool, max_nodes)
    if nav_recast.status_failed(status) {
        node_pool_destroy(&query.node_pool)
        return status
    }

    return {.Success}
}

// Destroy query object
nav_mesh_query_destroy :: proc(query: ^Nav_Mesh_Query) {
    node_queue_destroy(&query.open_list)
    node_pool_destroy(&query.node_pool)
    query^ = {}
}

// Find path using A* algorithm
find_path :: proc(query: ^Nav_Mesh_Query,
                    start_ref: nav_recast.Poly_Ref, end_ref: nav_recast.Poly_Ref,
                    start_pos: [3]f32, end_pos: [3]f32,
                    filter: ^Query_Filter,
                    path: []nav_recast.Poly_Ref,
                    max_path: i32) -> (status: nav_recast.Status, path_count: i32) {

    path_count = 0

    // Validate input
    if !is_valid_poly_ref(query.nav_mesh, start_ref) ||
       !is_valid_poly_ref(query.nav_mesh, end_ref) {
        return {.Invalid_Param}, 0
    }

    if start_ref == end_ref {
        if max_path > 0 {
            path[0] = start_ref
            path_count = 1
            return {.Success}, 1
        } else {
            return {.Buffer_Too_Small}, 0
        }
    }

    // Initialize search
    node_pool_clear(&query.node_pool)
    node_queue_clear(&query.open_list)

    start_node := node_pool_create_node(&query.node_pool, start_ref)
    if start_node == nil {
        return {.Out_Of_Nodes}, 0
    }

    start_node.pos = start_pos
    start_node.cost = 0
    start_node.total = linalg.distance(start_pos, end_pos) * H_SCALE
    start_node.id = start_ref
    start_node.flags = {.Open}
    start_node.parent_id = nav_recast.INVALID_POLY_REF

    start_pathfinding_node := Pathfinding_Node{
        ref = start_ref,
        cost = start_node.cost,
        total = start_node.total,
    }
    node_queue_push(&query.open_list, start_pathfinding_node)

    best_node := start_node
    best_dist := start_node.total
    
    iterations := 0
    max_iterations := 1000

    // Search loop
    for !node_queue_empty(&query.open_list) && iterations < max_iterations {
        iterations += 1
        // Get best node
        best_pathfinding_node := node_queue_pop(&query.open_list)
        if best_pathfinding_node.ref == nav_recast.INVALID_POLY_REF {
            break
        }
        current := node_pool_get_node(&query.node_pool, best_pathfinding_node.ref)
        if current == nil {
            continue
        }

        // Skip if already closed (duplicate entry that was processed)
        if .Closed in current.flags {
            continue
        }
        
        // Skip if this is a stale entry (cost doesn't match current best)
        if best_pathfinding_node.total != current.total {
            continue
        }

        // Mark as closed
        current.flags &= ~{.Open}
        current.flags |= {.Closed}

        // Debug logging
        if iterations <= 20 {
            log.debugf("Iter %d: Processing poly 0x%x (cost=%.2f, total=%.2f)", 
                      iterations, current.id, current.cost, current.total)
        }

        // Reached goal?
        if current.id == end_ref {
            best_node = current
            log.debugf("Goal reached at poly 0x%x after %d iterations", current.id, iterations)
            break
        }

        // Get current polygon
        cur_tile, cur_poly, status := get_tile_and_poly_by_ref(query.nav_mesh, current.id)
        if nav_recast.status_failed(status) {
            continue
        }

        // Explore neighbors
        // Iterate through all links from the current polygon
        link := cur_poly.first_link
        for link != nav_recast.DT_NULL_LINK {
            neighbor_ref := get_link_poly_ref(cur_tile, link)

            // Skip invalid ids and do not expand back to where we came from
            if neighbor_ref != nav_recast.INVALID_POLY_REF && neighbor_ref != current.parent_id {
                neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                if nav_recast.status_succeeded(neighbor_status) &&
                   query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {

                    // Check if neighbor node already exists
                    neighbor_node := node_pool_get_node(&query.node_pool, neighbor_ref)
                    
                    // Calculate neighbor position ONLY for new nodes
                    neighbor_pos: [3]f32
                    if neighbor_node == nil {
                        // Node doesn't exist yet, calculate position
                        left, right := [3]f32{}, [3]f32{}
                        portal_type := u8(0)
                        portal_status := get_portal_points(query, current.id, neighbor_ref, &left, &right, &portal_type)
                        
                        if nav_recast.status_succeeded(portal_status) {
                            // Use midpoint of the actual shared edge
                            neighbor_pos = linalg.mix(left, right, 0.5)
                        } else {
                            // Fallback to simple edge midpoint using link edge
                            link_edge := get_link_edge(cur_tile, link)
                            neighbor_pos = get_edge_mid_point(cur_tile, cur_poly, int(link_edge), neighbor_tile, neighbor_poly)
                        }
                    } else {
                        // Node already exists, always use cached position
                        neighbor_pos = neighbor_node.pos
                    }

                    // Calculate cost and heuristic
                    cost: f32
                    heuristic: f32
                    
                    // Special case for last node
                    if neighbor_ref == end_ref {
                        // Cost
                        cur_cost := query_filter_get_cost(filter,
                                                    current.pos, neighbor_pos,
                                                    current.parent_id, nil, nil,
                                                    current.id, cur_tile, cur_poly,
                                                    neighbor_ref, neighbor_tile, neighbor_poly)
                        end_cost := query_filter_get_cost(filter,
                                                    neighbor_pos, end_pos,
                                                    current.id, cur_tile, cur_poly,
                                                    neighbor_ref, neighbor_tile, neighbor_poly,
                                                    nav_recast.INVALID_POLY_REF, nil, nil)
                        cost = current.cost + cur_cost + end_cost
                        heuristic = 0
                    } else {
                        // Normal cost
                        cost = current.cost + query_filter_get_cost(filter,
                                                    current.pos, neighbor_pos,
                                                    current.parent_id, nil, nil,
                                                    current.id, cur_tile, cur_poly,
                                                    neighbor_ref, neighbor_tile, neighbor_poly)
                        heuristic = linalg.distance(neighbor_pos, end_pos) * H_SCALE
                    }

                    total := cost + heuristic
                    
                    // Debug logging
                    if iterations <= 20 && neighbor_ref == end_ref {
                        log.debugf("  Considering goal poly 0x%x: cost=%.2f, total=%.2f", 
                                  neighbor_ref, cost, total)
                        if neighbor_node != nil {
                            log.debugf("    Existing node: cost=%.2f, total=%.2f, open=%v, closed=%v",
                                      neighbor_node.cost, neighbor_node.total, 
                                      .Open in neighbor_node.flags, .Closed in neighbor_node.flags)
                        }
                    }
                    
                    // The node is already in open list and the new result is worse, skip
                    if neighbor_node != nil && .Open in neighbor_node.flags && total >= neighbor_node.total {
                        link = get_next_link(cur_tile, link)
                        continue
                    }
                    // The node is already visited and processed, and the new result is worse, skip
                    if neighbor_node != nil && .Closed in neighbor_node.flags && total >= neighbor_node.total {
                        link = get_next_link(cur_tile, link)
                        continue
                    }
                    
                    // Add or update the node
                    if neighbor_node == nil {
                        neighbor_node = node_pool_create_node(&query.node_pool, neighbor_ref)
                        if neighbor_node == nil {
                            // Out of nodes
                            break
                        }
                        // Set position only for new nodes
                        neighbor_node.pos = neighbor_pos
                    }

                    // If node was closed but we found a better path, reopen it
                    if .Closed in neighbor_node.flags {
                        neighbor_node.flags &= ~{.Closed}
                    }

                    // Update neighbor (but don't overwrite position of existing nodes)
                    neighbor_node.id = neighbor_ref
                    neighbor_node.parent_id = current.id
                    neighbor_node.cost = cost
                    neighbor_node.total = total
                    
                    // Mark as open (if not already)
                    neighbor_node.flags |= {.Open}
                    
                    // Always push to queue (duplicates will be filtered when popped)
                    neighbor_pathfinding_node := Pathfinding_Node{
                        ref = neighbor_ref,
                        cost = neighbor_node.cost,
                        total = neighbor_node.total,
                    }
                    node_queue_push(&query.open_list, neighbor_pathfinding_node)

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

    // Reconstruct path
    if best_node == nil {
        return {.Invalid_Param}, 0
    }

    return get_path_to_node(query, best_node, path, max_path)
}

// Get path from node back to start
get_path_to_node :: proc(query: ^Nav_Mesh_Query, end_node: ^Node,
                           path: []nav_recast.Poly_Ref, max_path: i32) -> (status: nav_recast.Status, path_count: i32) {

    // Count path length
    node := end_node
    length := i32(0)
    for node != nil {
        length += 1
        if node.parent_id == nav_recast.INVALID_POLY_REF {
            break
        }
        node = node_pool_get_node(&query.node_pool, node.parent_id)
    }

    if length > max_path {
        return {.Buffer_Too_Small}, 0
    }

    // Build path in reverse
    node = end_node
    for i := length - 1; i >= 0; i -= 1 {
        path[i] = node.id
        if node.parent_id == nav_recast.INVALID_POLY_REF {
            break
        }
        node = node_pool_get_node(&query.node_pool, node.parent_id)
    }

    return {.Success}, length
}

// Helper functions for link traversal and edge calculations

get_first_link :: proc(tile: ^Mesh_Tile, poly: i32) -> u32 {
    if poly < 0 || poly >= i32(len(tile.polys)) {
        return nav_recast.DT_NULL_LINK
    }
    return tile.polys[poly].first_link
}

get_next_link :: proc(tile: ^Mesh_Tile, link: u32) -> u32 {
    if link == nav_recast.DT_NULL_LINK || int(link) >= len(tile.links) {
        return nav_recast.DT_NULL_LINK
    }
    return tile.links[link].next
}

get_link_poly_ref :: proc(tile: ^Mesh_Tile, link: u32) -> nav_recast.Poly_Ref {
    if link == nav_recast.DT_NULL_LINK || int(link) >= len(tile.links) {
        return nav_recast.INVALID_POLY_REF
    }
    return tile.links[link].ref
}

get_link_edge :: proc(tile: ^Mesh_Tile, link: u32) -> u8 {
    if link == nav_recast.DT_NULL_LINK || int(link) >= len(tile.links) {
        return 0xff
    }
    return tile.links[link].edge
}

get_edge_mid_point :: proc(tile_a: ^Mesh_Tile, poly_a: ^Poly, edge: int,
                             tile_b: ^Mesh_Tile, poly_b: ^Poly) -> [3]f32 {
    // Get edge vertices
    va0 := tile_a.verts[poly_a.verts[edge]]
    va1 := tile_a.verts[poly_a.verts[(edge + 1) % int(poly_a.vert_count)]]

    // Return midpoint
    return linalg.mix(va0, va1, 0.5)
}

// Sliced pathfinding functions (matching C++ API)
init_sliced_find_path :: proc(query: ^Nav_Mesh_Query, start_ref: nav_recast.Poly_Ref,
                               end_ref: nav_recast.Poly_Ref, start_pos: [3]f32, end_pos: [3]f32,
                               filter: ^Query_Filter, options: u32) -> nav_recast.Status {
    
    // Validate input
    if !is_valid_poly_ref(query.nav_mesh, start_ref) || !is_valid_poly_ref(query.nav_mesh, end_ref) {
        return {.Invalid_Param}
    }
    
    // Initialize search state
    query.query_data.status = {.In_Progress}
    query.query_data.start_ref = start_ref
    query.query_data.end_ref = end_ref
    query.query_data.start_pos = start_pos
    query.query_data.end_pos = end_pos
    query.query_data.filter = filter
    query.query_data.options = options
    query.query_data.raycast_limit_squared = math.F32_MAX
    
    // Clear pools
    node_pool_clear(&query.node_pool)
    node_queue_clear(&query.open_list)
    
    // Create start node
    start_node := node_pool_create_node(&query.node_pool, start_ref)
    if start_node == nil {
        return {.Out_Of_Nodes}
    }
    
    start_node.pos = start_pos
    start_node.cost = 0
    start_node.total = linalg.distance(start_pos, end_pos) * H_SCALE
    start_node.flags = {.Open}
    start_node.parent_id = nav_recast.INVALID_POLY_REF
    
    node_queue_push(&query.open_list, {start_ref, start_node.cost, start_node.total})
    query.query_data.last_best = start_node
    
    return {.Success}
}

// Update sliced pathfinding
update_sliced_find_path :: proc(query: ^Nav_Mesh_Query, max_iter: i32, done_iters: ^i32) -> nav_recast.Status {
    if query.query_data.status != {.In_Progress} {
        if done_iters != nil {
            done_iters^ = 0
        }
        return query.query_data.status
    }
    
    iterations := i32(0)
    
    for !node_queue_empty(&query.open_list) && iterations < max_iter {
        iterations += 1
        
        // Get best node
        best := node_queue_pop(&query.open_list)
        if best.ref == nav_recast.INVALID_POLY_REF {
            break
        }
        
        current := node_pool_get_node(&query.node_pool, best.ref)
        if current == nil || .Closed in current.flags {
            continue
        }
        
        // Mark as closed
        current.flags |= {.Closed}
        current.flags &= ~{.Open}
        
        // Update best node
        if current.total < query.query_data.last_best.total {
            query.query_data.last_best = current
        }
        
        // Check if reached goal
        if current.id == query.query_data.end_ref {
            query.query_data.last_best = current
            query.query_data.status = {.Success}
            if done_iters != nil {
                done_iters^ = iterations
            }
            return query.query_data.status
        }
        
        // Expand neighbors (similar to find_path but simplified)
        cur_tile, cur_poly, status := get_tile_and_poly_by_ref(query.nav_mesh, current.id)
        if nav_recast.status_failed(status) {
            continue
        }
        
        link := cur_poly.first_link
        for link != nav_recast.DT_NULL_LINK {
            neighbor_ref := get_link_poly_ref(cur_tile, link)
            
            if neighbor_ref != nav_recast.INVALID_POLY_REF && neighbor_ref != current.parent_id {
                neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                if nav_recast.status_succeeded(neighbor_status) &&
                   query_filter_pass_filter(query.query_data.filter, neighbor_ref, neighbor_tile, neighbor_poly) {
                    
                    neighbor_node := node_pool_get_node(&query.node_pool, neighbor_ref)
                    
                    // Calculate position and cost
                    neighbor_pos: [3]f32
                    if neighbor_node == nil {
                        neighbor_pos = calc_poly_center(neighbor_tile, neighbor_poly)
                    } else {
                        neighbor_pos = neighbor_node.pos
                    }
                    
                    cost := current.cost + query_filter_get_cost(query.query_data.filter,
                                                current.pos, neighbor_pos,
                                                current.parent_id, nil, nil,
                                                current.id, cur_tile, cur_poly,
                                                neighbor_ref, neighbor_tile, neighbor_poly)
                    
                    heuristic := linalg.distance(neighbor_pos, query.query_data.end_pos) * H_SCALE
                    total := cost + heuristic
                    
                    // Skip if worse
                    if neighbor_node != nil && .Open in neighbor_node.flags && total >= neighbor_node.total {
                        link = get_next_link(cur_tile, link)
                        continue
                    }
                    if neighbor_node != nil && .Closed in neighbor_node.flags && total >= neighbor_node.total {
                        link = get_next_link(cur_tile, link)
                        continue
                    }
                    
                    // Add or update node
                    if neighbor_node == nil {
                        neighbor_node = node_pool_create_node(&query.node_pool, neighbor_ref)
                        if neighbor_node == nil {
                            break
                        }
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
                    
                    node_queue_push(&query.open_list, {neighbor_ref, neighbor_node.cost, neighbor_node.total})
                }
            }
            
            link = get_next_link(cur_tile, link)
        }
    }
    
    if done_iters != nil {
        done_iters^ = iterations
    }
    
    // Check if search is exhausted
    if node_queue_empty(&query.open_list) {
        query.query_data.status = {.Success} // Partial success - return best found
    }
    
    return query.query_data.status
}

// Finalize sliced pathfinding
finalize_sliced_find_path :: proc(query: ^Nav_Mesh_Query, path: []nav_recast.Poly_Ref, max_path: i32) -> (status: nav_recast.Status, path_count: i32) {
    
    if query.query_data.status != {.Success} {
        return query.query_data.status, 0
    }
    
    if query.query_data.last_best == nil {
        return {.Invalid_Param}, 0
    }
    
    return get_path_to_node(query, query.query_data.last_best, path, max_path)
}

// Finalize partial sliced pathfinding
finalize_sliced_find_path_partial :: proc(query: ^Nav_Mesh_Query, existing: []nav_recast.Poly_Ref, 
                                           path: []nav_recast.Poly_Ref, max_path: i32) -> (status: nav_recast.Status, path_count: i32) {
    
    if query.query_data.last_best == nil {
        return {.Invalid_Param}, 0
    }
    
    // Find the best polygon that was also visited in the existing path
    best_node := query.query_data.last_best
    
    // For simplicity, just return the best node found so far
    // A full implementation would find the closest node to the existing path
    return get_path_to_node(query, best_node, path, max_path)
}

// Convenience function: find path with slicing but complete it in one call
find_path_sliced :: proc(query: ^Nav_Mesh_Query, start_ref: nav_recast.Poly_Ref,
                           end_ref: nav_recast.Poly_Ref, start_pos: [3]f32, end_pos: [3]f32,
                           filter: ^Query_Filter, path: []nav_recast.Poly_Ref,
                           max_path: i32, max_iterations_per_slice: i32 = 50) -> (status: nav_recast.Status, path_count: i32) {
    // Initialize
    init_status := init_sliced_find_path(query, start_ref, end_ref, start_pos, end_pos, filter, 0)
    if nav_recast.status_failed(init_status) {
        return init_status, 0
    }
    
    // Run until completion
    iter_count := 0
    for iter_count < 10000 {
        done_iters := i32(0)
        update_status := update_sliced_find_path(query, max_iterations_per_slice, &done_iters)
        iter_count += int(done_iters)
        
        if update_status != {.In_Progress} {
            return finalize_sliced_find_path(query, path, max_path)
        }
    }
    
    return {.Out_Of_Nodes}, 0
}
