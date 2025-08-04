package navigation_detour

import "core:mem"
import "core:math"
import "core:math/linalg"
import "core:container/priority_queue"
import "core:slice"
import nav_recast "../recast"

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
    if a.total == b.total {
        // If total costs are equal, prefer lower individual cost
        if a.cost == b.cost {
            // If costs are also equal, use reference as tiebreaker for deterministic ordering
            return a.ref < b.ref
        }
        return a.cost < b.cost
    }
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
                    path: []nav_recast.Poly_Ref, path_count: ^i32,
                    max_path: i32) -> nav_recast.Status {
    
    path_count^ = 0
    
    // Validate input
    if !is_valid_poly_ref(query.nav_mesh, start_ref) || 
       !is_valid_poly_ref(query.nav_mesh, end_ref) {
        return {.Invalid_Param}
    }
    
    if start_ref == end_ref {
        path[0] = start_ref
        path_count^ = 1
        return {.Success}
    }
    
    // Initialize search
    node_pool_clear(&query.node_pool)
    node_queue_clear(&query.open_list)
    
    start_node := node_pool_create_node(&query.node_pool, start_ref)
    if start_node == nil {
        return {.Out_Of_Nodes}
    }
    
    start_node.pos = start_pos
    start_node.cost = 0
    start_node.total = linalg.distance(start_pos, end_pos)
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
    
    // Search loop
    for !node_queue_empty(&query.open_list) {
        // Get best node
        best_pathfinding_node := node_queue_pop(&query.open_list)
        if best_pathfinding_node.ref == nav_recast.INVALID_POLY_REF {
            break
        }
        current := node_pool_get_node(&query.node_pool, best_pathfinding_node.ref)
        if current == nil {
            continue
        }
        
        // Mark as closed
        current.flags &= ~{.Open}
        current.flags |= {.Closed}
        
        // Reached goal?
        if current.id == end_ref {
            best_node = current
            break
        }
        
        // Get current polygon
        cur_tile, cur_poly, status := get_tile_and_poly_by_ref(query.nav_mesh, current.id)
        if nav_recast.status_failed(status) {
            continue
        }
        
        // Explore neighbors
        for i in 0..<int(cur_poly.vert_count) {
            link := get_first_link(cur_tile, i32(current.id & 0xffff))
            for link != nav_recast.DT_NULL_LINK {
                neighbor_ref := get_link_poly_ref(cur_tile, link)
                
                if neighbor_ref != nav_recast.INVALID_POLY_REF {
                    neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                    if nav_recast.status_succeeded(neighbor_status) &&
                       query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {
                        
                        // Calculate neighbor position
                        neighbor_pos := get_edge_mid_point(cur_tile, cur_poly, i, neighbor_tile, neighbor_poly)
                        
                        // Calculate cost
                        cost := current.cost + query_filter_get_cost(filter, 
                                                    current.pos, neighbor_pos,
                                                    current.parent_id, nil, nil,
                                                    current.id, cur_tile, cur_poly,
                                                    neighbor_ref, neighbor_tile, neighbor_poly)
                        
                        // Check if this path to neighbor is better
                        neighbor_node := node_pool_get_node(&query.node_pool, neighbor_ref)
                        if neighbor_node == nil {
                            neighbor_node = node_pool_create_node(&query.node_pool, neighbor_ref)
                            if neighbor_node == nil {
                                // Out of nodes
                                break
                            }
                            neighbor_node.id = neighbor_ref
                        } else if cost >= neighbor_node.cost {
                            // Existing path is better
                            link = get_next_link(cur_tile, link)
                            continue
                        }
                        
                        // Update neighbor
                        neighbor_node.parent_id = current.id
                        neighbor_node.cost = cost
                        neighbor_node.pos = neighbor_pos
                        neighbor_node.total = neighbor_node.cost + linalg.distance(neighbor_pos, end_pos)
                        
                        // Always add the updated node to the queue
                        // The priority queue will handle ordering correctly
                        was_open := .Open in neighbor_node.flags
                        
                        if .Closed in neighbor_node.flags {
                            neighbor_node.flags &= ~{.Closed}
                        }
                        neighbor_node.flags |= {.Open}
                        
                        neighbor_pathfinding_node := Pathfinding_Node{
                            ref = neighbor_ref,
                            cost = neighbor_node.cost,
                            total = neighbor_node.total,
                        }
                        node_queue_push(&query.open_list, neighbor_pathfinding_node)
                        
                        // Update best node if closer to goal
                        heuristic := linalg.distance(neighbor_pos, end_pos)
                        if heuristic < best_dist {
                            best_dist = heuristic
                            best_node = neighbor_node
                        }
                    }
                }
                
                link = get_next_link(cur_tile, link)
            }
        }
    }
    
    // Reconstruct path
    if best_node == nil {
        return {.Invalid_Param}
    }
    
    return get_path_to_node(query, best_node, path, path_count, max_path)
}

// Get path from node back to start
get_path_to_node :: proc(query: ^Nav_Mesh_Query, end_node: ^Node, 
                           path: []nav_recast.Poly_Ref, path_count: ^i32, max_path: i32) -> nav_recast.Status {
    
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
        return {.Buffer_Too_Small}
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
    
    path_count^ = length
    return {.Success}
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

get_edge_mid_point :: proc(tile_a: ^Mesh_Tile, poly_a: ^Poly, edge: int,
                             tile_b: ^Mesh_Tile, poly_b: ^Poly) -> [3]f32 {
    // Get edge vertices
    va0 := tile_a.verts[poly_a.verts[edge]]
    va1 := tile_a.verts[poly_a.verts[(edge + 1) % int(poly_a.vert_count)]]
    
    // Return midpoint
    return {
        (va0[0] + va1[0]) * 0.5,
        (va0[1] + va1[1]) * 0.5,
        (va0[2] + va1[2]) * 0.5,
    }
}

// Sliced pathfinding state for spreading computation across frames
Sliced_Find_Path_State :: struct {
    query:          ^Nav_Mesh_Query,
    start_ref:      nav_recast.Poly_Ref,
    end_ref:        nav_recast.Poly_Ref, 
    start_pos:      [3]f32,
    end_pos:        [3]f32,
    filter:         ^Query_Filter,
    current_node:   ^Node,
    open_list:      [dynamic]Pathfinding_Node,
    iter_count:     i32,
    max_iterations: i32,
    status:         nav_recast.Status,
}

// Initialize sliced pathfinding - call this first
init_sliced_find_path :: proc(query: ^Nav_Mesh_Query, start_ref: nav_recast.Poly_Ref, 
                                end_ref: nav_recast.Poly_Ref, start_pos: [3]f32, end_pos: [3]f32,
                                filter: ^Query_Filter, options: u32) -> Sliced_Find_Path_State {
    
    state := Sliced_Find_Path_State{
        query = query,
        start_ref = start_ref,
        end_ref = end_ref,
        start_pos = start_pos,
        end_pos = end_pos,
        filter = filter,
        max_iterations = 2048, // Default max iterations per slice
        status = {.In_Progress},
    }
    
    // Initialize open list using standard allocator
    state.open_list = make([dynamic]Pathfinding_Node, 0, 128)
    
    // Validate input
    if query == nil || query.nav_mesh == nil || 
       start_ref == nav_recast.INVALID_POLY_REF || end_ref == nav_recast.INVALID_POLY_REF {
        state.status = {.Invalid_Param}
        return state
    }
    
    // Get starting node
    start_node := node_pool_get_node(&query.node_pool, start_ref)
    if start_node == nil {
        state.status = {.Out_Of_Nodes}
        return state
    }
    
    // Initialize start node
    start_node.pos = start_pos
    start_node.cost = 0
    start_node.total = linalg.distance(start_pos, end_pos)
    start_node.parent_id = nav_recast.INVALID_POLY_REF
    start_node.flags = {.Open}
    
    // Add to open list
    append(&state.open_list, Pathfinding_Node{
        ref = start_ref,
        total = start_node.total,
    })
    
    state.current_node = start_node
    
    return state
}

// Update sliced pathfinding - call this each frame until completion
update_sliced_find_path :: proc(state: ^Sliced_Find_Path_State, max_iter: i32) -> nav_recast.Status {
    
    if .In_Progress not_in state.status {
        return state.status
    }
    
    iterations_this_frame := i32(0)
    
    for len(state.open_list) > 0 && iterations_this_frame < max_iter {
        iterations_this_frame += 1
        state.iter_count += 1
        
        if state.iter_count >= state.max_iterations {
            state.status = {.Out_Of_Nodes}
            return state.status
        }
        
        // Get node with lowest cost
        best_index := 0
        for i in 1..<len(state.open_list) {
            if pathfinding_node_compare(state.open_list[i], state.open_list[best_index]) {
                best_index = i
            }
        }
        
        // Remove from open list
        current_ref := state.open_list[best_index].ref
        ordered_remove(&state.open_list, best_index)
        
        // Get current node
        current_node := node_pool_get_node(&state.query.node_pool, current_ref)
        if current_node == nil {
            continue
        }
        
        current_node.flags |= {.Closed}
        current_node.flags &= ~{.Open}
        
        // Check if we reached the goal
        if current_ref == state.end_ref {
            state.current_node = current_node
            state.status = {.Success}
            return state.status
        }
        
        // Get current tile and polygon
        cur_tile, cur_poly, tile_status := get_tile_and_poly_by_ref(state.query.nav_mesh, current_ref)
        if nav_recast.status_failed(tile_status) || cur_tile == nil || cur_poly == nil {
            continue
        }
        
        // Explore neighbors
        link := get_first_link(cur_tile, i32(current_ref & 0xffff))
        for link != nav_recast.DT_NULL_LINK {
            neighbor_ref := get_link_poly_ref(cur_tile, link)
            
            if neighbor_ref != nav_recast.INVALID_POLY_REF {
                neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(state.query.nav_mesh, neighbor_ref)
                if nav_recast.status_succeeded(neighbor_status) && neighbor_tile != nil && neighbor_poly != nil {
                    
                    // Check filter
                    if query_filter_pass_filter(state.filter, neighbor_ref, neighbor_tile, neighbor_poly) {
                        // Get neighbor node
                        neighbor_node := node_pool_get_node(&state.query.node_pool, neighbor_ref)
                        if neighbor_node != nil {
                            
                            // Calculate cost
                            neighbor_pos := calc_poly_center(neighbor_tile, neighbor_poly)
                            step_cost := linalg.distance(current_node.pos, neighbor_pos)
                            new_cost := current_node.cost + step_cost
                            
                            // If better path, update node
                            if .Closed not_in neighbor_node.flags {
                                if .Open not_in neighbor_node.flags || new_cost < neighbor_node.cost {
                                    neighbor_node.pos = neighbor_pos
                                    neighbor_node.cost = new_cost
                                    neighbor_node.total = new_cost + linalg.distance(neighbor_pos, state.end_pos)
                                    neighbor_node.parent_id = current_ref
                                    
                                    if .Open not_in neighbor_node.flags {
                                        neighbor_node.flags |= {.Open}
                                        append(&state.open_list, Pathfinding_Node{
                                            ref = neighbor_ref,
                                            total = neighbor_node.total,
                                        })
                                    }
                                }
                            }
                        }
                    }
                }
            }
            
            link = get_next_link(cur_tile, link)
        }
    }
    
    // Check if we ran out of nodes
    if len(state.open_list) == 0 {
        state.status = {.Invalid_Param} // No path found
    }
    
    return state.status
}

// Clean up sliced pathfinding state (call when done)
cleanup_sliced_find_path :: proc(state: ^Sliced_Find_Path_State) {
    if state.open_list != nil {
        delete(state.open_list)
        state.open_list = nil
    }
}

// Finalize sliced pathfinding and get the result path
finalize_sliced_find_path :: proc(state: ^Sliced_Find_Path_State, 
                                   path: []nav_recast.Poly_Ref, path_count: ^i32, max_path: i32) -> nav_recast.Status {
    
    if .Success not_in state.status {
        path_count^ = 0
        return state.status
    }
    
    if state.current_node == nil {
        path_count^ = 0
        return {.Invalid_Param}
    }
    
    // Reconstruct path from end node
    status := get_path_to_node(state.query, state.current_node, path, path_count, max_path)
    
    // Cleanup
    delete(state.open_list)
    
    return status
}

// Convenience function: find path with slicing but complete it in one call
find_path_sliced :: proc(query: ^Nav_Mesh_Query, start_ref: nav_recast.Poly_Ref, 
                           end_ref: nav_recast.Poly_Ref, start_pos: [3]f32, end_pos: [3]f32,
                           filter: ^Query_Filter, path: []nav_recast.Poly_Ref, 
                           path_count: ^i32, max_path: i32, max_iterations_per_slice: i32 = 50) -> nav_recast.Status {
    
    // Initialize
    state := init_sliced_find_path(query, start_ref, end_ref, start_pos, end_pos, filter, 0)
    
    // Run until completion
    for {
        if .In_Progress not_in state.status {
            break
        }
        update_sliced_find_path(&state, max_iterations_per_slice)
        
        // Safety check to prevent infinite loops
        if state.iter_count >= 10000 {
            delete(state.open_list)
            return {.Out_Of_Nodes}
        }
    }
    
    // Finalize
    return finalize_sliced_find_path(&state, path, path_count, max_path)
}
