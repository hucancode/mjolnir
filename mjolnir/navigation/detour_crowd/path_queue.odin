package navigation_detour_crowd

import "core:math"
import nav_recast "../recast"
import detour "../detour"

// Initialize path queue
dt_path_queue_init :: proc(queue: ^Dt_Path_Queue, max_path_size: i32, max_search_nodes: i32, 
                          nav_query: ^detour.Dt_Nav_Mesh_Query) -> nav_recast.Status {
    if queue == nil || max_path_size <= 0 || max_search_nodes <= 0 || nav_query == nil {
        return {.Invalid_Param}
    }
    
    queue.max_path_size = max_path_size
    queue.max_search_nodes = max_search_nodes
    queue.next_handle = 1  // Start from 1, 0 is invalid
    queue.max_queue = 8    // Default queue size
    queue.queue = make([dynamic]Dt_Path_Query, 0, queue.max_queue)
    queue.nav_query = nav_query
    
    return {.Success}
}

// Destroy path queue
dt_path_queue_destroy :: proc(queue: ^Dt_Path_Queue) {
    if queue == nil do return
    
    delete(queue.queue)
    queue.queue = nil
    queue.nav_query = nil
    queue.max_path_size = 0
    queue.max_search_nodes = 0
    queue.next_handle = 0
    queue.max_queue = 0
}

// Request path computation
dt_path_queue_request :: proc(queue: ^Dt_Path_Queue, start_ref, end_ref: nav_recast.Poly_Ref,
                             start_pos, end_pos: [3]f32, filter: ^detour.Dt_Query_Filter) -> (Dt_Path_Queue_Ref, nav_recast.Status) {
    
    if queue == nil || filter == nil {
        return Dt_Path_Queue_Ref(0), {.Invalid_Param}
    }
    
    if start_ref == nav_recast.INVALID_POLY_REF || end_ref == nav_recast.INVALID_POLY_REF {
        return Dt_Path_Queue_Ref(0), {.Invalid_Param}
    }
    
    // Check if queue is full
    if len(queue.queue) >= queue.max_queue {
        return Dt_Path_Queue_Ref(0), {.Buffer_Too_Small}
    }
    
    // Create new query
    query := Dt_Path_Query{
        ref = Dt_Path_Queue_Ref(queue.next_handle),
        start_ref = start_ref,
        end_ref = end_ref,
        start_pos = start_pos,
        end_pos = end_pos,
        status = {.In_Progress},
        keep_alive = 2,  // Keep alive for 2 updates
        filter = filter,
    }
    
    append(&queue.queue, query)
    
    ref := Dt_Path_Queue_Ref(queue.next_handle)
    queue.next_handle += 1
    
    return ref, {.Success}
}

// Update path queue - process pending queries
dt_path_queue_update :: proc(queue: ^Dt_Path_Queue, max_iter: i32) -> nav_recast.Status {
    if queue == nil {
        return {.Invalid_Param}
    }
    
    if queue.nav_query == nil {
        return {.Invalid_Param}
    }
    
    MAX_KEEP_ALIVE :: 2
    iter_count := i32(0)
    
    // Process queries in the queue
    for i := len(queue.queue) - 1; i >= 0; i -= 1 {
        query := &queue.queue[i]
        
        // Skip completed queries that are being kept alive
        if nav_recast.status_succeeded(query.status) {
            query.keep_alive -= 1
            if query.keep_alive <= 0 {
                // Remove completed query
                ordered_remove(&queue.queue, i)
            }
            continue
        }
        
        // Process this query
        if iter_count >= max_iter do break
        
        // Attempt to find path
        path_result := make([]nav_recast.Poly_Ref, queue.max_path_size)
        defer delete(path_result)
        
        path_count, find_status := detour.dt_find_path(
            queue.nav_query, query.start_ref, query.end_ref,
            query.start_pos, query.end_pos, query.filter, path_result
        )
        
        // Update query status
        if nav_recast.status_failed(find_status) {
            query.status = find_status
        } else {
            query.status = {.Success}
            if .Partial_Result in find_status {
                query.status |= {.Partial_Result}
            }
        }
        
        query.keep_alive = MAX_KEEP_ALIVE
        iter_count += 1
    }
    
    return {.Success}
}

// Get path result from completed query
dt_path_queue_get_request_status :: proc(queue: ^Dt_Path_Queue, ref: Dt_Path_Queue_Ref) -> nav_recast.Status {
    if queue == nil {
        return {.Invalid_Param}
    }
    
    if ref == Dt_Path_Queue_Ref(0) {
        return {.Invalid_Param}
    }
    
    // Find query in queue
    for &query in queue.queue {
        if query.ref == ref {
            return query.status
        }
    }
    
    return {.Invalid_Param}  // Query not found
}

// Get path from completed query
dt_path_queue_get_path_result :: proc(queue: ^Dt_Path_Queue, ref: Dt_Path_Queue_Ref, 
                                     path: []nav_recast.Poly_Ref) -> (i32, nav_recast.Status) {
    if queue == nil || len(path) == 0 {
        return 0, {.Invalid_Param}
    }
    
    if ref == Dt_Path_Queue_Ref(0) {
        return 0, {.Invalid_Param}
    }
    
    // Find query in queue
    for &query in queue.queue {
        if query.ref == ref {
            if !nav_recast.status_succeeded(query.status) {
                return 0, query.status
            }
            
            // Get path from navigation query
            path_result := make([]nav_recast.Poly_Ref, queue.max_path_size)
            defer delete(path_result)
            
            path_count, find_status := detour.dt_find_path(
                queue.nav_query, query.start_ref, query.end_ref,
                query.start_pos, query.end_pos, query.filter, path_result
            )
            
            if nav_recast.status_failed(find_status) {
                return 0, find_status
            }
            
            // Copy result to output buffer
            copy_count := min(path_count, i32(len(path)))
            for i in 0..<copy_count {
                path[i] = path_result[i]
            }
            
            return copy_count, query.status
        }
    }
    
    return 0, {.Invalid_Param}  // Query not found
}

// Remove/cancel a query
dt_path_queue_cancel_request :: proc(queue: ^Dt_Path_Queue, ref: Dt_Path_Queue_Ref) -> nav_recast.Status {
    if queue == nil {
        return {.Invalid_Param}
    }
    
    if ref == Dt_Path_Queue_Ref(0) {
        return {.Invalid_Param}
    }
    
    // Find and remove query
    for i, &query in queue.queue {
        if query.ref == ref {
            ordered_remove(&queue.queue, i)
            return {.Success}
        }
    }
    
    return {.Invalid_Param}  // Query not found
}

// Get queue statistics
dt_path_queue_get_stats :: proc(queue: ^Dt_Path_Queue) -> (queue_size: i32, max_queue_size: i32) {
    if queue == nil {
        return 0, 0
    }
    
    return i32(len(queue.queue)), queue.max_queue
}

// Check if queue is full
dt_path_queue_is_full :: proc(queue: ^Dt_Path_Queue) -> bool {
    if queue == nil do return true
    return len(queue.queue) >= queue.max_queue
}

// Check if queue is empty
dt_path_queue_is_empty :: proc(queue: ^Dt_Path_Queue) -> bool {
    if queue == nil do return true
    return len(queue.queue) == 0
}

// Get number of pending queries
dt_path_queue_get_pending_count :: proc(queue: ^Dt_Path_Queue) -> i32 {
    if queue == nil do return 0
    
    count := i32(0)
    for &query in queue.queue {
        if nav_recast.status_in_progress(query.status) {
            count += 1
        }
    }
    
    return count
}

// Get number of completed queries
dt_path_queue_get_completed_count :: proc(queue: ^Dt_Path_Queue) -> i32 {
    if queue == nil do return 0
    
    count := i32(0)
    for &query in queue.queue {
        if nav_recast.status_succeeded(query.status) {
            count += 1
        }
    }
    
    return count
}

// Clear all queries from queue
dt_path_queue_clear :: proc(queue: ^Dt_Path_Queue) {
    if queue == nil do return
    clear(&queue.queue)
}

// Resize queue capacity
dt_path_queue_resize :: proc(queue: ^Dt_Path_Queue, new_max_queue: i32) -> nav_recast.Status {
    if queue == nil || new_max_queue <= 0 {
        return {.Invalid_Param}
    }
    
    queue.max_queue = new_max_queue
    
    // If current queue is larger than new max, truncate it
    if len(queue.queue) > new_max_queue {
        resize(&queue.queue, new_max_queue)
    }
    
    return {.Success}
}

// Check if a reference is valid
dt_path_queue_is_valid_ref :: proc(queue: ^Dt_Path_Queue, ref: Dt_Path_Queue_Ref) -> bool {
    if queue == nil || ref == Dt_Path_Queue_Ref(0) {
        return false
    }
    
    for &query in queue.queue {
        if query.ref == ref {
            return true
        }
    }
    
    return false
}

// Get query information (for debugging)
dt_path_queue_get_query_info :: proc(queue: ^Dt_Path_Queue, ref: Dt_Path_Queue_Ref) -> (start_ref: nav_recast.Poly_Ref, end_ref: nav_recast.Poly_Ref, 
                                                                                        start_pos: [3]f32, end_pos: [3]f32, status: nav_recast.Status, found: bool) {
    if queue == nil || ref == Dt_Path_Queue_Ref(0) {
        return nav_recast.INVALID_POLY_REF, nav_recast.INVALID_POLY_REF, {}, {}, {.Invalid_Param}, false
    }
    
    for &query in queue.queue {
        if query.ref == ref {
            return query.start_ref, query.end_ref, query.start_pos, query.end_pos, query.status, true
        }
    }
    
    return nav_recast.INVALID_POLY_REF, nav_recast.INVALID_POLY_REF, {}, {}, {.Invalid_Param}, false
}

// Force completion of a specific query (synchronous processing)
dt_path_queue_force_complete :: proc(queue: ^Dt_Path_Queue, ref: Dt_Path_Queue_Ref) -> nav_recast.Status {
    if queue == nil || ref == Dt_Path_Queue_Ref(0) {
        return {.Invalid_Param}
    }
    
    // Find query in queue
    for &query in queue.queue {
        if query.ref == ref {
            if nav_recast.status_succeeded(query.status) {
                return query.status  // Already completed
            }
            
            // Force immediate processing
            path_result := make([]nav_recast.Poly_Ref, queue.max_path_size)
            defer delete(path_result)
            
            path_count, find_status := detour.dt_find_path(
                queue.nav_query, query.start_ref, query.end_ref,
                query.start_pos, query.end_pos, query.filter, path_result
            )
            
            // Update query status
            if nav_recast.status_failed(find_status) {
                query.status = find_status
            } else {
                query.status = {.Success}
                if .Partial_Result in find_status {
                    query.status |= {.Partial_Result}
                }
            }
            
            query.keep_alive = 2
            return query.status
        }
    }
    
    return {.Invalid_Param}  // Query not found
}