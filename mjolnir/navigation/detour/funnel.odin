package navigation_detour

import "core:math"
import "core:math/linalg"
import "core:log"
import nav_recast "../recast"

// Find straight path using funnel algorithm for path smoothing
find_straight_path :: proc(query: ^Nav_Mesh_Query,
                             start_pos: [3]f32, end_pos: [3]f32,
                             path: []nav_recast.Poly_Ref, path_count: i32,
                             straight_path: []Straight_Path_Point,
                             straight_path_flags: []u8, straight_path_refs: []nav_recast.Poly_Ref,
                             straight_path_count: ^i32, max_straight_path: i32,
                             options: u32) -> nav_recast.Status {

    straight_path_count^ = 0

    // Validate input parameters
    if query == nil || query.nav_mesh == nil {
        return {.Invalid_Param}
    }

    if path_count == 0 {
        return {.Invalid_Param}
    }

    stat := nav_recast.Status{}

    // Portal vertices for funnel algorithm
    portal_apex := start_pos
    portal_left := start_pos
    portal_right := start_pos

    apex_index := i32(0)
    left_index := i32(0)
    right_index := i32(0)

    left_poly_ref := nav_recast.INVALID_POLY_REF
    right_poly_ref := nav_recast.INVALID_POLY_REF

    if path_count > 0 {
        left_poly_ref = path[0]
        right_poly_ref = path[0]
    }

    n_straight_path := i32(0)

    // Add start point
    if n_straight_path < max_straight_path {
        straight_path[n_straight_path] = {
            pos = start_pos,
            flags = u8(Straight_Path_Flags.Start),
            ref = path[0] if path_count > 0 else nav_recast.INVALID_POLY_REF,
        }
        n_straight_path += 1
    } else {
        stat |= {.Buffer_Too_Small}
    }

    // Process path corridors
    // The funnel algorithm should process exactly path_count-1 portal segments
    // plus one final segment to the end position
    i := i32(0)
    funnel_restarts := 0
    max_restarts := path_count * 2  // Allow more restarts since we might need to process some portals multiple times
    
    // Track how many times we've processed each index to prevent infinite loops
    process_counts := make([]i32, path_count, context.temp_allocator)

    // log.infof("Funnel: Starting with path_count=%d, start_pos=%v, end_pos=%v", path_count, start_pos, end_pos)

    for i <= path_count { // Include one extra iteration for the end position
        // Prevent infinite loops by limiting how many times we process the same index
        if i < path_count {
            process_counts[i] += 1
            if process_counts[i] > 3 {
                log.errorf("Processed index %d too many times, breaking to prevent infinite loop", i)
                break
            }
        }
        
        // For the last iteration, we process from the last polygon to the end position
        from_ref := nav_recast.INVALID_POLY_REF
        to_ref := nav_recast.INVALID_POLY_REF
        
        if i < path_count {
            from_ref = path[i]
            if i + 1 < path_count {
                to_ref = path[i + 1]
            }
        } else if path_count > 0 {
            // Special case: processing from last polygon to end position
            from_ref = path[path_count - 1]
            to_ref = nav_recast.INVALID_POLY_REF
        }
        
        // log.infof("Funnel: Processing i=%d, from_ref=0x%x, to_ref=0x%x", i, from_ref, to_ref)

        // Get portal between polygons
        left: [3]f32
        right: [3]f32
        portal_type := u8(0)

        if to_ref == nav_recast.INVALID_POLY_REF {
            // Last polygon, use end position
            left = end_pos
            right = end_pos
            portal_type = u8(Straight_Path_Flags.End)
            // log.infof("  Last polygon, using end position as portal: %v", end_pos)
        } else {
            // Get portal between from_ref and to_ref
            portal_status := get_portal_points(query, from_ref, to_ref, &left, &right, &portal_type)
            if nav_recast.status_failed(portal_status) {
                // Could not get portal, use current polygon center
                from_tile, from_poly, _ := get_tile_and_poly_by_ref(query.nav_mesh, from_ref)
                if from_tile != nil && from_poly != nil {
                    center := calc_poly_center(from_tile, from_poly)
                    left = center
                    right = center
                    // log.warnf("  Failed to get portal, using polygon center: %v", center)
                }
            } else {
                // log.infof("  Got portal: left=%v, right=%v", left, right)
            }
        }

        // Funnel algorithm

        // If moving around the funnel, skip this portal
        if i > 0 {
            // Special case: if we're at apex_index and the current portal would be degenerate, advance
            if i == apex_index && linalg.length2(portal_right - portal_left) < 0.001 {
                // log.infof("  Skipping degenerate portal at apex index %d", i)
                i += 1
                continue
            }
            
            // Right vertex
            perp_right := nav_recast.vec2f_perp(portal_apex, portal_right, right)
            perp_left := nav_recast.vec2f_perp(portal_apex, portal_left, right)
            // log.infof("  Right vertex check: apex=%v, portal_right=%v, right=%v, perp_right=%f, perp_left=%f", 
            //           portal_apex, portal_right, right, perp_right, perp_left)
            
            if perp_right <= 0.0 {
                if perp_left > 0.0 {
                    // Tighten the funnel
                    portal_right = right
                    right_poly_ref = from_ref
                    right_index = i
                } else {
                    // Right vertex is crossing left edge, advance apex
                    // log.infof("    Right vertex crossing left edge, advancing apex to left at index %d", left_index)
                    if n_straight_path < max_straight_path {
                        straight_path[n_straight_path] = {
                            pos = portal_left,
                            flags = u8(Straight_Path_Flags.Start) if left_index == 0 else 0,
                            ref = left_poly_ref,
                        }
                        n_straight_path += 1
                    } else {
                        stat |= {.Buffer_Too_Small}
                    }

                    // Move apex to left vertex
                    portal_apex = portal_left
                    apex_index = left_index

                    // Reset portal - but ensure we don't have a degenerate funnel
                    // When apex advances to left side, the new right side is the old apex
                    portal_left = portal_apex
                    portal_right = portal_apex
                    left_index = apex_index
                    right_index = apex_index
                    left_poly_ref = path[apex_index]
                    right_poly_ref = path[apex_index]

                    // Restart scan from apex
                    funnel_restarts += 1
                    // log.infof("    Restart #%d: apex_index=%d, i will be %d", funnel_restarts, apex_index, apex_index)
                    if i32(funnel_restarts) > max_restarts {
                        log.errorf("Funnel algorithm exceeded restart limit (%d), path may be corrupted", max_restarts)
                        stat |= {.Out_Of_Nodes}
                        break
                    }

                    // Always make forward progress - restart from max of current position or apex+1
                    i = max(i + 1, apex_index + 1)
                    continue
                }
            }

            // Left vertex
            perp_left2 := nav_recast.vec2f_perp(portal_apex, portal_left, left)
            perp_right2 := nav_recast.vec2f_perp(portal_apex, portal_right, left)
            // log.infof("  Left vertex check: apex=%v, portal_left=%v, left=%v, perp_left=%f, perp_right=%f", 
            //           portal_apex, portal_left, left, perp_left2, perp_right2)
            
            if perp_left2 >= 0.0 {
                if perp_right2 < 0.0 {
                    // Tighten the funnel
                    portal_left = left
                    left_poly_ref = from_ref
                    left_index = i
                } else {
                    // Left vertex is crossing right edge, advance apex
                    // log.infof("    Left vertex crossing right edge, advancing apex to right at index %d", right_index)
                    if n_straight_path < max_straight_path {
                        straight_path[n_straight_path] = {
                            pos = portal_right,
                            flags = u8(Straight_Path_Flags.Start) if right_index == 0 else 0,
                            ref = right_poly_ref,
                        }
                        n_straight_path += 1
                    } else {
                        stat |= {.Buffer_Too_Small}
                    }

                    // Move apex to right vertex
                    portal_apex = portal_right
                    apex_index = right_index

                    // Reset portal - but ensure we don't have a degenerate funnel
                    // When apex advances to right side, the new left side is the old apex
                    portal_left = portal_apex
                    portal_right = portal_apex
                    left_index = apex_index
                    right_index = apex_index
                    left_poly_ref = path[apex_index]
                    right_poly_ref = path[apex_index]

                    // Restart scan from apex
                    funnel_restarts += 1
                    // log.infof("    Restart #%d: apex_index=%d, i will be %d", funnel_restarts, apex_index, apex_index)
                    if i32(funnel_restarts) > max_restarts {
                        log.errorf("Funnel algorithm exceeded restart limit (%d), path may be corrupted", max_restarts)
                        stat |= {.Out_Of_Nodes}
                        break
                    }

                    // Always make forward progress - restart from max of current position or apex+1
                    i = max(i + 1, apex_index + 1)
                    continue
                }
            }
        } else {
            // First iteration, set initial portal
            portal_left = left
            portal_right = right
            left_index = i
            right_index = i
            left_poly_ref = from_ref
            right_poly_ref = from_ref
        }

        i += 1  // Advance to next corridor
    }

    if funnel_restarts > 0 {
        // log.debugf("Funnel algorithm completed with %d restarts", funnel_restarts)
    }

    // Add end point
    if n_straight_path < max_straight_path {
        straight_path[n_straight_path] = {
            pos = end_pos,
            flags = u8(Straight_Path_Flags.End),
            ref = path[path_count - 1] if path_count > 0 else nav_recast.INVALID_POLY_REF,
        }
        n_straight_path += 1
    } else {
        stat |= {.Buffer_Too_Small}
    }

    straight_path_count^ = i32(n_straight_path)

    // If no errors occurred, mark as successful
    if stat == {} {
        stat |= {.Success}
    }

    return stat
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
    for i in 0..<int(from_poly.vert_count) {
        // Check if this edge connects to target polygon
        nei := from_poly.neis[i]
        // log.infof("  Edge %d: nei=%d", i, nei)
        
        // Check direct neighbor reference (1-based index)
        if nei > 0 && i32(nei - 1) == i32(to & 0xffff) {
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
        link := get_first_link(from_tile, i32(from & 0xffff))
        for link != nav_recast.DT_NULL_LINK {
            link_ref := get_link_poly_ref(from_tile, link)
            // log.infof("    Link to: 0x%x", link_ref)
            if link_ref == to {
                // Found the connection, extract portal vertices
                va := from_tile.verts[from_poly.verts[i]]
                vb := from_tile.verts[from_poly.verts[(i + 1) % int(from_poly.vert_count)]]

                // Portal vertices should be ordered consistently
                // For a portal from polygon A to polygon B, the vertices should be
                // ordered such that when walking from A to B, left is on the left side
                left^ = va
                right^ = vb
                portal_type^ = 0

                // log.infof("  Found portal via link: left=%v right=%v", va, vb)
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

    return nav_recast.point_in_polygon_2d(pos, verts)
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
            link := get_first_link(tile, i32(ref & 0xffff))
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
