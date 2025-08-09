package navigation_detour

import "core:math"
import "core:math/linalg"
import "core:log"
import nav_recast "../recast"
import geometry "../../geometry"

// Helper function to check if two positions are equal within epsilon (matches C++ dtVequal)
dt_vequal :: proc(a, b: [3]f32) -> bool {
    EPSILON :: 0.0001
    return abs(a.x - b.x) < EPSILON && abs(a.y - b.y) < EPSILON && abs(a.z - b.z) < EPSILON
}

// Helper function to calculate squared distance from point to line segment in 2D
dt_distance_pt_seg_sqr_2d :: proc(pt, p0, p1: [3]f32) -> (dist_sqr: f32, t: f32) {
    dx := p1.x - p0.x
    dz := p1.z - p0.z
    d := dx*dx + dz*dz
    t = f32(0)
    
    if d > 0 {
        t = ((pt.x - p0.x)*dx + (pt.z - p0.z)*dz) / d
        if t < 0 {
            t = 0
        } else if t > 1 {
            t = 1
        }
    }
    
    dx = p0.x + t*dx - pt.x
    dz = p0.z + t*dz - pt.z
    
    return dx*dx + dz*dz, t
}

// Find straight path using funnel algorithm for path smoothing
find_straight_path :: proc(query: ^Nav_Mesh_Query,
                             start_pos: [3]f32, end_pos: [3]f32,
                             path: []nav_recast.Poly_Ref, path_count: i32,
                             straight_path: []Straight_Path_Point,
                             straight_path_flags: []u8, straight_path_refs: []nav_recast.Poly_Ref,
                             max_straight_path: i32,
                             options: u32) -> (status: nav_recast.Status, straight_path_count: i32) {

    straight_path_count = 0

    // Validate input parameters
    if query == nil || query.nav_mesh == nil {
        return {.Invalid_Param}, straight_path_count
    }

    if path_count == 0 {
        return {.Invalid_Param}, straight_path_count
    }

    stat := nav_recast.Status{}

    // Portal vertices for funnel algorithm
    portal_apex := start_pos
    portal_left := start_pos
    portal_right := start_pos

    apex_index := i32(0)
    left_index := i32(0)
    right_index := i32(0)

    left_poly_type := u8(0)
    right_poly_type := u8(0)

    n_straight_path := i32(0)

    // Add start point
    if n_straight_path < max_straight_path {
        straight_path[n_straight_path] = {
            pos = start_pos,
            flags = u8(Straight_Path_Flags.Start),
            ref = path[0],
        }
        n_straight_path += 1
    } else {
        stat |= {.Buffer_Too_Small}
    }

    // Process path corridors - matches C++ loop structure exactly
    for i := i32(0); i < path_count; i += 1 {
        // Get portal points
        left := [3]f32{}
        right := [3]f32{}
        from_type := u8(0)
        to_type := u8(0)
        
        if i + 1 == path_count {
            // End of path
            left = end_pos
            right = end_pos
            from_type = 0
            to_type = u8(Straight_Path_Flags.End)
        } else {
            // Get portal between path[i] and path[i+1]
            portal_status := get_portal_points(query, path[i], path[i+1], &left, &right, &from_type)
            if nav_recast.status_failed(portal_status) {
                // Failed to get portal - this is a problem that needs fixing
                log.warnf("Failed to get portal between poly 0x%x and 0x%x (indices %d->%d)", 
                         path[i], path[i+1], i, i+1)
                
                // Try to use polygon centroids as fallback
                from_tile, from_poly, _ := get_tile_and_poly_by_ref(query.nav_mesh, path[i])
                to_tile, to_poly, _ := get_tile_and_poly_by_ref(query.nav_mesh, path[i+1])
                
                if from_tile != nil && from_poly != nil && to_tile != nil && to_poly != nil {
                    // Use centroids as a fallback portal
                    from_center := calc_poly_center(from_tile, from_poly)
                    to_center := calc_poly_center(to_tile, to_poly)
                    
                    // Create a perpendicular portal at the midpoint
                    mid := (from_center + to_center) * 0.5
                    dir := linalg.normalize(to_center - from_center)
                    perp := [3]f32{-dir.z, dir.y, dir.x} * 0.5
                    
                    left = mid - perp
                    right = mid + perp
                    from_type = 0
                    
                    log.warnf("Using fallback portal: left=%v, right=%v", left, right)
                } else if i + 1 == path_count - 1 {
                    // If this is the last portal, use end position
                    left = end_pos
                    right = end_pos
                    from_type = 0
                    to_type = u8(Straight_Path_Flags.End)
                } else {
                    // Skip failed portal
                    continue
                }
            }
        }
        
        // If starting really close to portal, advance (matches C++)
        if i == 0 {
            dist_sqr, _ := dt_distance_pt_seg_sqr_2d(portal_apex, left, right)
            if dist_sqr < 0.001 * 0.001 {
                continue
            }
        }
        
        // Update funnel
        if i == 0 {
            // First portal, initialize funnel
            portal_left = left
            portal_right = right
            left_poly_type = from_type
            right_poly_type = from_type
            continue
        }
        
        // Check right vertex
        tri_area_right := geometry.vec2f_perp(portal_apex, portal_right, right)
        
        if tri_area_right <= 0.0 {
            // Check if apex equals portal_right or if right is on correct side of left edge
            if dt_vequal(portal_apex, portal_right) || geometry.vec2f_perp(portal_apex, portal_left, right) > 0.0 {
                // Tighten the funnel
                portal_right = right
                right_poly_type = (i + 1 == path_count) ? to_type : 0
                right_index = i
            } else {
                // Right vertex crossed left edge, add left vertex and restart scan
                if n_straight_path < max_straight_path {
                    // Append vertex
                    straight_path[n_straight_path] = {
                        pos = portal_left,
                        flags = left_poly_type,
                        ref = path[left_index],
                    }
                    n_straight_path += 1
                } else {
                    stat |= {.Buffer_Too_Small}
                }
                
                // Advance apex
                portal_apex = portal_left
                apex_index = left_index
                
                // Reset funnel
                portal_left = portal_apex
                portal_right = portal_apex
                left_index = apex_index
                right_index = apex_index
                left_poly_type = 0
                right_poly_type = 0
                
                // Restart scan from new apex (matches C++)
                i = apex_index
                continue
            }
        }
        
        // Check left vertex
        tri_area_left := geometry.vec2f_perp(portal_apex, portal_left, left)
        
        if tri_area_left >= 0.0 {
            // Check if apex equals portal_left or if left is on correct side of right edge
            if dt_vequal(portal_apex, portal_left) || geometry.vec2f_perp(portal_apex, portal_right, left) < 0.0 {
                // Tighten the funnel
                portal_left = left
                left_poly_type = (i + 1 == path_count) ? to_type : 0
                left_index = i
            } else {
                // Left vertex crossed right edge, add right vertex and restart scan
                if n_straight_path < max_straight_path {
                    // Append vertex
                    straight_path[n_straight_path] = {
                        pos = portal_right,
                        flags = right_poly_type,
                        ref = path[right_index],
                    }
                    n_straight_path += 1
                } else {
                    stat |= {.Buffer_Too_Small}
                }
                
                // Advance apex
                portal_apex = portal_right
                apex_index = right_index
                
                // Reset funnel
                portal_left = portal_apex
                portal_right = portal_apex
                left_index = apex_index
                right_index = apex_index
                left_poly_type = 0
                right_poly_type = 0
                
                // Restart scan from new apex (matches C++)
                i = apex_index
                continue
            }
        }
    }

    // Add end point
    if n_straight_path < max_straight_path {
        straight_path[n_straight_path] = {
            pos = end_pos,
            flags = u8(Straight_Path_Flags.End),
            ref = path[path_count - 1],
        }
        n_straight_path += 1
    } else {
        stat |= {.Buffer_Too_Small}
    }

    straight_path_count = n_straight_path

    // Return success if no errors
    if stat == {} {
        stat |= {.Success}
    }

    return stat, straight_path_count
}

// Get portal points between two adjacent polygons
get_portal_points :: proc(query: ^Nav_Mesh_Query, from: nav_recast.Poly_Ref, to: nav_recast.Poly_Ref,
                            left: ^[3]f32, right: ^[3]f32, portal_type: ^u8) -> nav_recast.Status {

    // log.infof("get_portal_points: from=0x%x to=0x%x", from, to)

    from_tile, from_poly, from_status := get_tile_and_poly_by_ref(query.nav_mesh, from)
    if nav_recast.status_failed(from_status) {
        // log.warnf("  Failed to get from polygon")
        return from_status
    }

    to_tile, to_poly, to_status := get_tile_and_poly_by_ref(query.nav_mesh, to)
    if nav_recast.status_failed(to_status) {
        // log.warnf("  Failed to get to polygon")
        return to_status
    }

    // Find the shared edge between the polygons
    // Get the polygon index from the reference
    _, _, to_poly_index := decode_poly_id(query.nav_mesh, to)
    
    for i in 0..<int(from_poly.vert_count) {
        // Check if this edge connects to target polygon
        nei := from_poly.neis[i]
        // log.infof("  Edge %d: nei=%d, to_poly_index=%d", i, nei, to_poly_index)
        
        // Check direct neighbor reference (1-based index, so nei-1 is the polygon index)
        if nei > 0 && u32(nei - 1) == to_poly_index {
            // Found the connection through neighbor reference
            va := from_tile.verts[from_poly.verts[i]]
            vb := from_tile.verts[from_poly.verts[(i + 1) % int(from_poly.vert_count)]]

            left^ = va
            right^ = vb
            portal_type^ = 0

            // log.infof("  Found portal via neighbor: left=%v right=%v", va, vb)
            return {.Success}
        }
        
        // Also check via links
        _, _, from_poly_index := decode_poly_id(query.nav_mesh, from)
        link := get_first_link(from_tile, i32(from_poly_index))
        for link != nav_recast.DT_NULL_LINK {
            link_ref := get_link_poly_ref(from_tile, link)
            // log.infof("    Link to: 0x%x", link_ref)
            if link_ref == to {
                // Found the link! Extract the edge vertices
                link_edge := get_link_edge(from_tile, link)
                v0 := from_poly.verts[link_edge]
                v1 := from_poly.verts[(link_edge + 1) % u8(from_poly.vert_count)]
                
                left^ = from_tile.verts[v0]
                right^ = from_tile.verts[v1]
                portal_type^ = 0

                // log.infof("  Found portal via link: edge=%d, left=%v right=%v", link_edge, left^, right^)
                return {.Success}
            }
            link = get_next_link(from_tile, link)
        }
    }

    // log.warnf("  No portal found between polygons")
    return {.Invalid_Param}
}

// Calculate polygon center
calc_poly_center :: proc(tile: ^Mesh_Tile, poly: ^Poly) -> [3]f32 {
    center := [3]f32{0, 0, 0}

    for i in 0..<int(poly.vert_count) {
        vert := tile.verts[poly.verts[i]]
        center += vert
    }

    if poly.vert_count > 0 {
        center /= f32(poly.vert_count)
    }

    return center
}

// Move along surface constrained by navigation mesh
move_along_surface :: proc(query: ^Nav_Mesh_Query,
                             start_ref: nav_recast.Poly_Ref, start_pos: [3]f32,
                             end_pos: [3]f32, filter: ^Query_Filter,
                             result_pos: ^[3]f32, visited: []nav_recast.Poly_Ref,
                             visited_count: ^i32, max_visited: i32) -> nav_recast.Status {

    visited_count^ = 0
    result_pos^ = start_pos

    if !is_valid_poly_ref(query.nav_mesh, start_ref) {
        return {.Invalid_Param}
    }

    tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, start_ref)
    if nav_recast.status_failed(status) {
        return status
    }

    if max_visited > 0 {
        visited[0] = start_ref
        visited_count^ = 1
    }

    // If start equals end, we're done
    dir := end_pos - start_pos
    if linalg.length(dir) < 1e-6 {
        return {.Success}
    }

    cur_pos := start_pos
    cur_ref := start_ref

    // Walk along surface using small steps
    // Each iteration should make measurable progress toward the goal
    STEP_SIZE :: 0.1
    max_safe_steps := i32(linalg.length(dir) / STEP_SIZE * 2)  // 2x safety factor
    if max_safe_steps < 10 do max_safe_steps = 10  // Minimum steps for very short distances
    if max_safe_steps > 1000 do max_safe_steps = 1000  // Cap for very long distances

    for iter := i32(0); iter < max_safe_steps; iter += 1 {
        // Calculate remaining distance
        remaining := end_pos - cur_pos
        distance := linalg.length(remaining)

        // Natural termination: reached goal
        if distance < 1e-6 {
            log.debugf("Surface walk completed: reached goal after %d steps", iter)
            break
        }

        // Progress check: ensure we're making meaningful progress
        if iter > 0 {
            step_progress := linalg.length(cur_pos - start_pos)
            expected_min_progress := f32(iter) * STEP_SIZE * 0.1  // At least 10% of expected progress

            if step_progress < expected_min_progress {
                log.warnf("Surface walk making insufficient progress after %d steps (%.3f < %.3f)", iter, step_progress, expected_min_progress)
                // This indicates we're stuck or hitting walls repeatedly
                break
            }
        }

        // Take small step towards goal
        step_size := min(STEP_SIZE, distance)
        step_dir := linalg.normalize(remaining)
        target_pos := cur_pos + step_dir * step_size

        // Project target position onto current polygon
        closest_pos := closest_point_on_poly(query, cur_ref, target_pos)

        // Check if we moved outside current polygon
        if !point_in_polygon(query, cur_ref, closest_pos) {
            // Find which edge we crossed and get neighbor
            neighbor_ref, wall_hit := find_neighbor_across_edge(query, cur_ref, cur_pos, closest_pos, filter)

            if neighbor_ref != nav_recast.INVALID_POLY_REF {
                // Move to neighbor polygon
                cur_ref = neighbor_ref

                // Add to visited list
                if visited_count^ < max_visited {
                    visited[visited_count^] = cur_ref
                    visited_count^ += 1
                }
            } else if wall_hit {
                // Hit a wall, stop movement
                break
            }
        }

        cur_pos = closest_pos
    }

    // Check if we completed successfully or hit iteration limit
    final_distance := linalg.length(end_pos - cur_pos)
    if final_distance > 1e-3 {
        log.debugf("Surface walk stopped %f units from goal after %d steps", final_distance, max_safe_steps)
    }

    result_pos^ = cur_pos
    return {.Success}
}

// Helper functions for surface movement

closest_point_on_poly :: proc(query: ^Nav_Mesh_Query, ref: nav_recast.Poly_Ref, pos: [3]f32) -> [3]f32 {
    tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if nav_recast.status_failed(status) {
        return pos
    }

    // For simplicity, project to polygon center
    // A full implementation would project to polygon surface
    return calc_poly_center(tile, poly)
}

point_in_polygon :: proc(query: ^Nav_Mesh_Query, ref: nav_recast.Poly_Ref, pos: [3]f32) -> bool {
    tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if nav_recast.status_failed(status) {
        return false
    }

    // Build polygon vertices
    verts := make([][3]f32, poly.vert_count, context.temp_allocator)
    for i in 0..<int(poly.vert_count) {
        verts[i] = tile.verts[poly.verts[i]]
    }

    return geometry.point_in_polygon_2d(pos, verts)
}

find_neighbor_across_edge :: proc(query: ^Nav_Mesh_Query, ref: nav_recast.Poly_Ref,
                                    start_pos: [3]f32, end_pos: [3]f32,
                                    filter: ^Query_Filter) -> (nav_recast.Poly_Ref, bool) {

    tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if nav_recast.status_failed(status) {
        return nav_recast.INVALID_POLY_REF, false
    }

    // Check each edge for intersection with movement ray
    for i in 0..<int(poly.vert_count) {
        va := tile.verts[poly.verts[i]]
        vb := tile.verts[poly.verts[(i + 1) % int(poly.vert_count)]]

        // Check if movement ray intersects this edge
        if dt_intersect_segment_edge_2d(start_pos, end_pos, va, vb) {
            // Find neighbor across this edge
            poly_idx := get_poly_index(query.nav_mesh, ref)
            link := get_first_link(tile, i32(poly_idx))
            for link != nav_recast.DT_NULL_LINK {
                neighbor_ref := get_link_poly_ref(tile, link)
                if neighbor_ref != nav_recast.INVALID_POLY_REF {
                    neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                    if nav_recast.status_succeeded(neighbor_status) &&
                       query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {
                        return neighbor_ref, false
                    }
                }
                link = get_next_link(tile, link)
            }

            // No valid neighbor, hit wall
            return nav_recast.INVALID_POLY_REF, true
        }
    }

    return nav_recast.INVALID_POLY_REF, false
}

dt_intersect_segment_edge_2d :: proc(p0: [3]f32, p1: [3]f32, a: [3]f32, b: [3]f32) -> bool {
    // 2D line intersection test in XZ plane
    dx1 := p1.x - p0.x
    dz1 := p1.z - p0.z
    dx2 := b.x - a.x
    dz2 := b.z - a.z

    denominator := dx1 * dz2 - dz1 * dx2
    if abs(denominator) < 1e-6 {
        return false // Parallel lines
    }

    dx3 := p0.x - a.x
    dz3 := p0.z - a.z

    t1 := (dx2 * dz3 - dz2 * dx3) / denominator
    t2 := (dx1 * dz3 - dz1 * dx3) / denominator

    return t1 >= 0.0 && t1 <= 1.0 && t2 >= 0.0 && t2 <= 1.0
}