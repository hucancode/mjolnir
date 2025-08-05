package navigation_detour_crowd

import "core:math"
import "core:slice"
import nav_recast "../recast"
import detour "../detour"

// Initialize path corridor
path_corridor_init :: proc(corridor: ^Path_Corridor, max_path: i32) -> nav_recast.Status {
    if corridor == nil || max_path <= 0 {
        return {.Invalid_Param}
    }
    
    corridor.path = make([dynamic]nav_recast.Poly_Ref, 0, max_path)
    corridor.max_path = max_path
    corridor.position = {}
    corridor.target = {}
    
    return {.Success}
}

// Destroy path corridor
path_corridor_destroy :: proc(corridor: ^Path_Corridor) {
    if corridor == nil do return
    
    delete(corridor.path)
    corridor.path = nil
    corridor.max_path = 0
}

// Reset corridor to a specific position
path_corridor_reset :: proc(corridor: ^Path_Corridor, ref: nav_recast.Poly_Ref, pos: [3]f32) -> nav_recast.Status {
    if corridor == nil {
        return {.Invalid_Param}
    }
    
    clear(&corridor.path)
    if ref != nav_recast.INVALID_POLY_REF {
        append(&corridor.path, ref)
    }
    
    corridor.position = pos
    corridor.target = pos
    
    return {.Success}
}

// Find corners in the corridor from position toward target
path_corridor_find_corners :: proc(corridor: ^Path_Corridor,
                                     corner_verts: []f32, corner_flags: []u8, corner_polys: []nav_recast.Poly_Ref,
                                     max_corners: i32, nav_query: ^detour.Nav_Mesh_Query, 
                                     filter: ^detour.Query_Filter) -> (i32, nav_recast.Status) {
    
    if corridor == nil || nav_query == nil || filter == nil || max_corners <= 0 {
        return 0, {.Invalid_Param}
    }
    
    if len(corridor.path) == 0 {
        return 0, {.Success}
    }
    
    max_straight := min(DT_CROWD_MAX_CORNERS, max_corners)
    
    // Convert dynamic slice to regular slice for the query
    path_slice := corridor.path[:]
    
    // Create buffers for straight path results
    straight_path := make([]detour.Straight_Path_Point, max_straight)
    defer delete(straight_path)
    
    // Find straight path from current position to target
    straight_count, status := detour.find_straight_path(
        nav_query, corridor.position, corridor.target, path_slice,
        straight_path, detour.Straight_Path_Options{},
    )
    
    if nav_recast.status_failed(status) {
        return 0, status
    }
    
    // Convert results to output format
    corner_count := min(straight_count, max_corners)
    for i in 0..<corner_count {
        if i*3+2 < len(corner_verts) {
            corner_verts[i*3+0] = straight_path[i].pos[0]
            corner_verts[i*3+1] = straight_path[i].pos[1]
            corner_verts[i*3+2] = straight_path[i].pos[2]
        }
        
        if i < len(corner_flags) {
            corner_flags[i] = u8(straight_path[i].flags)
        }
        
        if i < len(corner_polys) {
            corner_polys[i] = straight_path[i].ref
        }
    }
    
    return corner_count, {.Success}
}

// Optimize path visibility by checking if next position is visible
path_corridor_optimize_path_visibility :: proc(corridor: ^Path_Corridor, next: [3]f32, 
                                                  path_optimization_range: f32, nav_query: ^detour.Nav_Mesh_Query,
                                                  filter: ^detour.Query_Filter) -> nav_recast.Status {
    
    if corridor == nil || nav_query == nil || filter == nil {
        return {.Invalid_Param}
    }
    
    if len(corridor.path) == 0 {
        return {.Success}
    }
    
    // Check if we can see further along the path
    result_path := make([]nav_recast.Poly_Ref, corridor.max_path)
    defer delete(result_path)
    
    // Perform raycast to see how far we can optimize
    status, hit, _ := detour.raycast(nav_query, corridor.path[0], corridor.position, next, filter, 0, result_path, corridor.max_path)
    if nav_recast.status_failed(status) {
        return status
    }
    
    // If we didn't hit anything, we can optimize toward the target
    if hit.t >= 1.0 {
        // Find the polygon containing the next position
        next_ref, _, query_status := detour.find_nearest_poly(nav_query, next, {2,2,2}, filter)
        if nav_recast.status_succeeded(query_status) && next_ref != nav_recast.INVALID_POLY_REF {
            // Replace the path up to this point
            clear(&corridor.path)
            append(&corridor.path, next_ref)
        }
    }
    
    return {.Success}
}

// Optimize path topology using local area search
path_corridor_optimize_path_topology :: proc(corridor: ^Path_Corridor, nav_query: ^detour.Nav_Mesh_Query,
                                                filter: ^detour.Query_Filter) -> (bool, nav_recast.Status) {
    
    if corridor == nil || nav_query == nil || filter == nil {
        return false, {.Invalid_Param}
    }
    
    if len(corridor.path) < 3 {
        return false, {.Success}
    }
    
    // Try to optimize by checking shortcuts through nearby polygons
    MAX_ITER :: 32
    MAX_LOOK_AHEAD :: 6
    MAX_RES :: 32
    
    optimized := false
    
    for iter in 0..<MAX_ITER {
        if len(corridor.path) < 3 do break
        
        // Find polygons around current position
        polys := make([]nav_recast.Poly_Ref, MAX_RES)
        defer delete(polys)
        
        poly_count, status := detour.dt_find_polys_around_circle(
            nav_query, corridor.path[0], corridor.position, 
            8.0, filter, polys
        )
        
        if nav_recast.status_failed(status) do break
        
        // Try to find shortcuts through these polygons
        look_ahead := min(MAX_LOOK_AHEAD, len(corridor.path))
        
        for i in 2..<look_ahead {
            // Check if we can reach polygon i directly
            for j in 0..<poly_count {
                if polys[j] == corridor.path[i] {
                    // We found a shortcut - remove intermediate polygons
                    new_path := make([dynamic]nav_recast.Poly_Ref, 0, corridor.max_path)
                    defer delete(new_path)
                    
                    append(&new_path, corridor.path[0])
                    
                    for k in i..<len(corridor.path) {
                        append(&new_path, corridor.path[k])
                    }
                    
                    // Replace the path
                    clear(&corridor.path)
                    for poly in new_path {
                        append(&corridor.path, poly)
                    }
                    
                    optimized = true
                    break
                }
            }
            if optimized do break
        }
        
        if !optimized do break
    }
    
    return optimized, {.Success}
}

// Move position along the corridor
path_corridor_move_position :: proc(corridor: ^Path_Corridor, new_pos: [3]f32, 
                                      nav_query: ^detour.Nav_Mesh_Query, filter: ^detour.Query_Filter) -> (bool, nav_recast.Status) {
    
    if corridor == nil || nav_query == nil || filter == nil {
        return false, {.Invalid_Param}
    }
    
    if len(corridor.path) == 0 {
        return false, {.Success}
    }
    
    // Find the polygon containing the new position
    MAX_VISITED :: 16
    visited := make([]nav_recast.Poly_Ref, MAX_VISITED)
    defer delete(visited)
    
    visited_count, status := detour.move_along_surface(
        nav_query, corridor.path[0], corridor.position, new_pos, filter, visited
    )
    
    if nav_recast.status_failed(status) {
        return false, status
    }
    
    // Update the corridor path with visited polygons
    if visited_count > 0 {
        // Merge the visited polygons into the corridor
        new_path := make([dynamic]nav_recast.Poly_Ref, 0, corridor.max_path)
        defer delete(new_path)
        
        // Add visited polygons
        for i in 0..<visited_count {
            append(&new_path, visited[i])
        }
        
        // Add remaining path
        start_idx := 1
        if visited_count > 0 {
            // Find where the visited path connects to the existing path
            for i in 1..<len(corridor.path) {
                if corridor.path[i] == visited[visited_count-1] {
                    start_idx = i + 1
                    break
                }
            }
        }
        
        for i in start_idx..<len(corridor.path) {
            append(&new_path, corridor.path[i])
        }
        
        // Replace the corridor path
        clear(&corridor.path)
        for poly in new_path {
            append(&corridor.path, poly)
        }
    }
    
    corridor.position = new_pos
    return true, {.Success}
}

// Move target to new position
path_corridor_move_target :: proc(corridor: ^Path_Corridor, new_target: [3]f32,
                                    nav_query: ^detour.Nav_Mesh_Query, filter: ^detour.Query_Filter) -> nav_recast.Status {
    
    if corridor == nil || nav_query == nil || filter == nil {
        return {.Invalid_Param}
    }
    
    // Find the polygon containing the new target
    target_ref, _, status := detour.find_nearest_poly(nav_query, new_target, {2,2,2}, filter)
    if nav_recast.status_failed(status) {
        return status
    }
    
    if target_ref == nav_recast.INVALID_POLY_REF {
        return {.Invalid_Param}
    }
    
    // If the target is in a polygon we already have, just update target position
    for poly in corridor.path {
        if poly == target_ref {
            corridor.target = new_target
            return {.Success}
        }
    }
    
    // Need to extend path to new target
    if len(corridor.path) > 0 {
        path_result := make([]nav_recast.Poly_Ref, corridor.max_path)
        defer delete(path_result)
        
        // Find path from current end to new target
        last_poly := corridor.path[len(corridor.path)-1]
        path_count, find_status := detour.find_path(
            nav_query, last_poly, target_ref, corridor.target, new_target, filter, path_result
        )
        
        if nav_recast.status_succeeded(find_status) && path_count > 1 {
            // Append new path (skip first polygon as it's already in corridor)
            for i in 1..<path_count {
                if len(corridor.path) < corridor.max_path {
                    append(&corridor.path, path_result[i])
                }
            }
        }
    }
    
    corridor.target = new_target
    return {.Success}
}

// Check if the corridor path is valid
path_corridor_is_valid :: proc(corridor: ^Path_Corridor, max_look_ahead: i32,
                                 nav_query: ^detour.Nav_Mesh_Query, filter: ^detour.Query_Filter) -> (bool, nav_recast.Status) {
    
    if corridor == nil || nav_query == nil || filter == nil {
        return false, {.Invalid_Param}
    }
    
    if len(corridor.path) == 0 {
        return true, {.Success}
    }
    
    // Check a limited number of polygons ahead
    check_count := min(max_look_ahead, i32(len(corridor.path)))
    
    for i in 0..<check_count {
        poly_ref := corridor.path[i]
        
        // Check if polygon is still valid
        tile, poly, status := detour.get_tile_and_poly_by_ref(nav_query.nav_mesh, poly_ref)
        if nav_recast.status_failed(status) || tile == nil || poly == nil {
            return false, {.Success}
        }
        
        // Check if polygon passes filter
        if !detour.query_filter_pass_filter(filter, poly_ref, tile, poly) {
            return false, {.Success}
        }
    }
    
    return true, {.Success}
}

// Fix path start if current start polygon is invalid
path_corridor_fix_path_start :: proc(corridor: ^Path_Corridor, safe_ref: nav_recast.Poly_Ref, safe_pos: [3]f32) -> nav_recast.Status {
    if corridor == nil {
        return {.Invalid_Param}
    }
    
    if safe_ref == nav_recast.INVALID_POLY_REF {
        return {.Invalid_Param}
    }
    
    // Replace the start of the path with the safe reference
    if len(corridor.path) == 0 {
        append(&corridor.path, safe_ref)
    } else {
        corridor.path[0] = safe_ref
    }
    
    corridor.position = safe_pos
    
    return {.Success}
}

// Trim invalid path back to a safe polygon
path_corridor_trim_invalid_path :: proc(corridor: ^Path_Corridor, safe_ref: nav_recast.Poly_Ref, safe_pos: [3]f32,
                                          nav_query: ^detour.Nav_Mesh_Query, filter: ^detour.Query_Filter) -> nav_recast.Status {
    
    if corridor == nil || nav_query == nil || filter == nil {
        return {.Invalid_Param}
    }
    
    if safe_ref == nav_recast.INVALID_POLY_REF {
        return {.Invalid_Param}
    }
    
    // Find the safe polygon in the current path
    safe_index := -1
    for i, poly in corridor.path {
        if poly == safe_ref {
            safe_index = i
            break
        }
    }
    
    if safe_index == -1 {
        // Safe polygon not in path, replace entire path
        clear(&corridor.path)
        append(&corridor.path, safe_ref)
        corridor.position = safe_pos
        corridor.target = safe_pos
    } else {
        // Trim path to safe polygon
        new_length := safe_index + 1
        resize(&corridor.path, new_length)
        corridor.position = safe_pos
    }
    
    return {.Success}
}

// Get the first polygon in the path
path_corridor_get_first_poly :: proc(corridor: ^Path_Corridor) -> nav_recast.Poly_Ref {
    if corridor == nil || len(corridor.path) == 0 {
        return nav_recast.INVALID_POLY_REF
    }
    return corridor.path[0]
}

// Get the last polygon in the path
path_corridor_get_last_poly :: proc(corridor: ^Path_Corridor) -> nav_recast.Poly_Ref {
    if corridor == nil || len(corridor.path) == 0 {
        return nav_recast.INVALID_POLY_REF
    }
    return corridor.path[len(corridor.path)-1]
}

// Get the target polygon
path_corridor_get_target :: proc(corridor: ^Path_Corridor) -> [3]f32 {
    if corridor == nil {
        return {}
    }
    return corridor.target
}

// Get current position
path_corridor_get_pos :: proc(corridor: ^Path_Corridor) -> [3]f32 {
    if corridor == nil {
        return {}
    }
    return corridor.position
}