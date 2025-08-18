package navigation_detour

import "core:math"
import "core:math/linalg"
import "core:log"
import recast "../recast"
import geometry "../../geometry"



// Find straight path using funnel algorithm for path smoothing
find_straight_path :: proc(query: ^Nav_Mesh_Query,
                             start_pos: [3]f32, end_pos: [3]f32,
                             path: []recast.Poly_Ref, path_count: i32,
                             straight_path: []Straight_Path_Point,
                             straight_path_flags: []u8, straight_path_refs: []recast.Poly_Ref,
                             max_straight_path: i32,
                             options: u32) -> (status: recast.Status, straight_path_count: i32) {

    straight_path_count = 0

    // Validate input parameters
    if query == nil || query.nav_mesh == nil {
        return {.Invalid_Param}, straight_path_count
    }

    if path_count == 0 || path[0] == recast.INVALID_POLY_REF || max_straight_path <= 0 {
        return {.Invalid_Param}, straight_path_count
    }

    stat :recast.Status

    // Clamp start and end positions to polygon boundaries (matches C++)
    closest_start_pos, start_status := closest_point_on_poly_boundary_nav(query, path[0], start_pos)
    if recast.status_failed(start_status) {
        return {.Invalid_Param}, straight_path_count
    }

    closest_end_pos, end_status := closest_point_on_poly_boundary_nav(query, path[path_count-1], end_pos)
    if recast.status_failed(end_status) {
        return {.Invalid_Param}, straight_path_count
    }

    // Portal vertices for funnel algorithm
    portal_apex := closest_start_pos
    portal_left := closest_start_pos
    portal_right := closest_start_pos

    apex_index := i32(0)
    left_index := i32(0)
    right_index := i32(0)

    left_poly_type := u8(0)
    right_poly_type := u8(0)

    n_straight_path := i32(0)

    // Add start point
    if n_straight_path < max_straight_path {
        straight_path[n_straight_path] = {
            pos = closest_start_pos,
            flags = u8(Straight_Path_Flags.Start),
            ref = path[0],
        }
        n_straight_path += 1
    } else {
        stat |= {.Buffer_Too_Small}
    }


    // Special case for single polygon path
    if path_count == 1 {
        // For a single polygon, the path is just start -> end
        // Add end point
        if n_straight_path < max_straight_path {
            straight_path[n_straight_path] = {
                pos = closest_end_pos,
                flags = u8(Straight_Path_Flags.End),
                ref = path[0],
            }
            n_straight_path += 1
        } else {
            stat |= {.Buffer_Too_Small}
        }
        straight_path_count = n_straight_path
        return stat | {.Success}, straight_path_count
    }

    // Path has more than one polygon - run funnel algorithm
    if path_count > 1 {
        // Debug: log the path
        // log.debugf("find_straight_path: Processing path with %d polygons:", path_count)
        // for i in 0..<path_count {
        //     log.debugf("  Path[%d] = 0x%x", i, path[i])
        // }

        // Process portals using funnel algorithm
        // Need higher limit for complex paths with many resets
        MAX_ITERATIONS :: 1000
        iteration_count := i32(0)
        last_progress_i := i32(-1)
        stuck_count := i32(0)

        for i := i32(0); i < path_count; i += 1 {
            iteration_count += 1
            if iteration_count > MAX_ITERATIONS {
                log.errorf("find_straight_path: Infinite loop detected after %d iterations! i=%d, path_count=%d, apex=%d, left=%d, right=%d",
                          iteration_count, i, path_count, apex_index, left_index, right_index)
                // Force termination with partial result
                break
            }

            // Track progress to detect getting stuck
            if i == last_progress_i {
                stuck_count += 1
                if stuck_count > 10 {
                    log.warnf("find_straight_path: Stuck at i=%d for %d iterations, forcing progress", i, stuck_count)
                    i += 1
                    stuck_count = 0
                    last_progress_i = i
                    continue
                }
            } else {
                last_progress_i = i
                stuck_count = 0
            }

            left: [3]f32
            right: [3]f32
            to_type := u8(0)

            if i + 1 < path_count {
                // Get portal between path[i] and path[i+1]
                from_type: u8
                portal_status: recast.Status
                left, right, from_type, portal_status = get_portal_points(query, path[i], path[i+1])

                // Debug logging for stuck case
                if iteration_count > 50 && i == 2 {
                    log.debugf("Portal at i=%d: left=%v, right=%v, status=%v", i, left, right, portal_status)
                    log.debugf("  Apex=%v, Portal_left=%v, Portal_right=%v", portal_apex, portal_left, portal_right)
                }

                if recast.status_failed(portal_status) {
                    // Failed to get portal points - clamp end point to current polygon
                    // This matches the C++ behavior
                    closest_on_poly, _ := closest_point_on_poly_boundary_nav(query, path[i], closest_end_pos)

                    // Add the end point and return partial result
                    if n_straight_path < max_straight_path {
                        straight_path[n_straight_path] = {
                            pos = closest_on_poly,
                            flags = 0,
                            ref = path[i],
                        }
                        n_straight_path += 1
                    }

                    if n_straight_path < max_straight_path {
                        straight_path[n_straight_path] = {
                            pos = closest_on_poly,
                            flags = u8(Straight_Path_Flags.End),
                            ref = path[i],
                        }
                        n_straight_path += 1
                    }

                    straight_path_count = n_straight_path
                    return stat | {.Success, .Partial_Result}, straight_path_count
                }

                // If starting really close to the portal, advance (matches C++)
                if i == 0 {
                    dist_sqr, _ := geometry.point_segment_distance2_2d(portal_apex, left, right)
                    if dist_sqr < 0.001 * 0.001 {  // dtSqr(0.001f) in C++
                        i += 1  // Manually increment and continue
                        continue
                    }
                }
            } else {
                // End of path
                left = closest_end_pos
                right = closest_end_pos
                to_type = u8(Straight_Path_Flags.End)
            }

            // Update right vertex (matches C++ dtTriArea2D check)
            if geometry.perpendicular_cross_2d(portal_apex, portal_right, right) <= 0.0 {
                if geometry.vector_equal(portal_apex, portal_right) || geometry.perpendicular_cross_2d(portal_apex, portal_left, right) > 0.0 {
                    // Tighten the funnel
                    portal_right = right
                    if i + 1 < path_count {
                        right_poly_type = to_type
                    }
                    right_index = i
                } else {
                    // Right vertex crossed left edge, add left vertex and restart scan
                    // Avoid adding duplicate points
                    if n_straight_path == 0 || !geometry.vector_equal(portal_left, straight_path[n_straight_path-1].pos) {
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
                    }

                    // Advance apex
                    portal_apex = portal_left
                    prev_apex_index := apex_index
                    apex_index = left_index

                    // Reset funnel
                    portal_left = portal_apex
                    portal_right = portal_apex
                    left_index = apex_index
                    right_index = apex_index
                    left_poly_type = 0
                    right_poly_type = 0

                    // Restart scan from new apex
                    // IMPORTANT: In C++, i = apexIndex sets i to apex, but the for loop's ++i
                    // increments it before the next iteration. We need to emulate this.
                    i = apex_index
                    continue
                }
            }


            // Update left vertex (matches C++ dtTriArea2D check)
            if geometry.perpendicular_cross_2d(portal_apex, portal_left, left) >= 0.0 {
                if geometry.vector_equal(portal_apex, portal_left) || geometry.perpendicular_cross_2d(portal_apex, portal_right, left) < 0.0 {
                    // Tighten the funnel
                    portal_left = left
                    if i + 1 < path_count {
                        left_poly_type = to_type
                    }
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
                    prev_apex_index := apex_index
                    apex_index = right_index

                    // Reset funnel
                    portal_left = portal_apex
                    portal_right = portal_apex
                    left_index = apex_index
                    right_index = apex_index
                    left_poly_type = 0
                    right_poly_type = 0

                    // Restart scan from new apex
                    // IMPORTANT: In C++, i = apexIndex sets i to apex, but the for loop's ++i
                    // increments it before the next iteration. We need to emulate this.
                    i = apex_index
                    continue
                }
            }
        }
    }

    // Add end point (always use clamped end position)
    if n_straight_path < max_straight_path {
        straight_path[n_straight_path] = {
            pos = closest_end_pos,
            flags = u8(Straight_Path_Flags.End),
            ref = 0,  // C++ uses 0 for end point
        }
        n_straight_path += 1
    } else {
        stat |= {.Buffer_Too_Small}
    }

    straight_path_count = n_straight_path

    // Copy flags and polygon refs to output arrays if provided
    if straight_path_flags != nil {
        for i in 0..<n_straight_path {
            if int(i) < len(straight_path_flags) {
                straight_path_flags[i] = straight_path[i].flags
            }
        }
    }

    if straight_path_refs != nil {
        for i in 0..<n_straight_path {
            if int(i) < len(straight_path_refs) {
                straight_path_refs[i] = straight_path[i].ref
            }
        }
    }


    // Return success if no errors
    if stat == {} {
        stat |= {.Success}
    }

    return stat, straight_path_count
}

// Get portal points between two adjacent polygons
get_portal_points :: proc(query: ^Nav_Mesh_Query, from: recast.Poly_Ref, to: recast.Poly_Ref) -> (left: [3]f32, right: [3]f32, portal_type: u8, status: recast.Status) {

    // log.debugf("get_portal_points: from=0x%x to=0x%x", from, to)

    from_tile, from_poly, from_status := get_tile_and_poly_by_ref(query.nav_mesh, from)
    if recast.status_failed(from_status) {
        log.errorf("  FAILED: Could not get from polygon 0x%x, status=%v", from, from_status)
        return {}, {}, 0, from_status
    }

    to_tile, to_poly, to_status := get_tile_and_poly_by_ref(query.nav_mesh, to)
    if recast.status_failed(to_status) {
        log.errorf("  FAILED: Could not get to polygon 0x%x, status=%v", to, to_status)
        return {}, {}, 0, to_status
    }

    // Decode polygon references for detailed logging
    from_salt, from_tile_idx, from_poly_idx := decode_poly_id(query.nav_mesh, from)
    to_salt, to_tile_idx, to_poly_idx := decode_poly_id(query.nav_mesh, to)

    // log.debugf("  FROM: poly_idx=%d, tile_idx=%d, salt=%d, vert_count=%d",
    //          from_poly_idx, from_tile_idx, from_salt, from_poly.vert_count)
    // log.debugf("  TO: poly_idx=%d, tile_idx=%d, salt=%d, vert_count=%d",
    //          to_poly_idx, to_tile_idx, to_salt, to_poly.vert_count)

    // // Log polygon vertices for debugging
    // log.debugf("  FROM polygon vertices:")
    // for i in 0..<int(from_poly.vert_count) {
    //     vert_idx := from_poly.verts[i]
    //     if int(vert_idx) < len(from_tile.verts) {
    //         vert := from_tile.verts[vert_idx]
    //         log.debugf("    [%d] vert_idx=%d, pos=%v", i, vert_idx, vert)
    //     } else {
    //         log.errorf("    [%d] INVALID vert_idx=%d (max=%d)", i, vert_idx, len(from_tile.verts)-1)
    //     }
    // }
    //
    // log.debugf("  TO polygon vertices:")
    // for i in 0..<int(to_poly.vert_count) {
    //     vert_idx := to_poly.verts[i]
    //     if int(vert_idx) < len(to_tile.verts) {
    //         vert := to_tile.verts[vert_idx]
    //         log.debugf("    [%d] vert_idx=%d, pos=%v", i, vert_idx, vert)
    //     } else {
    //         log.errorf("    [%d] INVALID vert_idx=%d (max=%d)", i, vert_idx, len(to_tile.verts)-1)
    //     }
    // }

    // First try to find via links (most reliable method)
    // log.debugf("  METHOD 1: Searching via links from poly 0x%x (first_link=%d) to find 0x%x",
    //           from, from_poly.first_link, to)
    link := from_poly.first_link
    link_count := 0
    max_links_to_check := 20  // Safety limit

    for link != recast.DT_NULL_LINK && link_count < max_links_to_check {
        if int(link) >= len(from_tile.links) {
            log.errorf("    INVALID link index %d (max=%d)", link, len(from_tile.links)-1)
            break
        }

        link_info := &from_tile.links[link]
        link_ref := link_info.ref
        link_edge := link_info.edge
        link_side := link_info.side

        link_count += 1
        // log.debugf("    Link %d: idx=%d, edge=%d, side=%d, ref=0x%x (target=0x%x)",
        //          link_count, link, link_edge, link_side, link_ref, to)

        if link_ref == to {
            // Found the link! Extract the edge vertices
            // log.debugf("    MATCH FOUND! Extracting edge vertices...")

            if int(link_edge) >= int(from_poly.vert_count) {
                log.errorf("      INVALID edge index %d (poly has %d vertices)", link_edge, from_poly.vert_count)
                link = link_info.next
                continue
            }

            v0_idx := from_poly.verts[link_edge]
            v1_idx := from_poly.verts[(link_edge + 1) % u8(from_poly.vert_count)]

            // log.debugf("      Edge vertices: v0_idx=%d, v1_idx=%d", v0_idx, v1_idx)

            if int(v0_idx) >= len(from_tile.verts) || int(v1_idx) >= len(from_tile.verts) {
                log.errorf("      INVALID vertex indices: v0=%d, v1=%d (max=%d)",
                          v0_idx, v1_idx, len(from_tile.verts)-1)
                link = link_info.next
                continue
            }

            v0_pos := from_tile.verts[v0_idx]
            v1_pos := from_tile.verts[v1_idx]

            // log.debugf("      v0=%v, v1=%v", v0_pos, v1_pos)

            // Note: The order matters! In a right-handed system with Y-up,
            // when traversing from 'from' to 'to', left should be on the left side
            // For now, swap them to match C++ behavior
            left = v1_pos
            right = v0_pos
            portal_type = 0

            // log.debugf("      SUCCESS: Portal found via link - left=%v, right=%v", left, right)
            return left, right, portal_type, {.Success}
        }

        link = link_info.next
    }

    if link_count >= max_links_to_check {
        log.errorf("    Hit link traversal safety limit (%d), possible infinite loop", max_links_to_check)
    }

    // log.infof("    Links checked: %d, no match found", link_count)

    // Fallback: check neighbor references
    // log.infof("  METHOD 2: Checking neighbor references...")
    // log.infof("    Same tile check: from_tile=%d, to_tile=%d", from_tile_idx, to_tile_idx)

    // Check if they're in the same tile (neighbor references only work within tile)
    if from_tile_idx == to_tile_idx {
        // log.infof("    Polygons are in same tile, checking neighbor array...")

        for i in 0..<int(from_poly.vert_count) {
            nei := from_poly.neis[i]
            // log.infof("      Edge %d: neighbor=0x%x", i, nei)

            nei_idx: u32

            // Check if this is an external link (0x8000 flag set)
            if nei & 0x8000 != 0 {
                // External link - the lower bits contain the neighbor index
                nei_idx = u32(nei & 0x7fff)
                // log.infof("        External link to index: %d (looking for %d)", nei_idx, to_poly_idx)
            } else if nei > 0 && nei <= 0x3f {  // Internal edge marker
                nei_idx = u32(nei - 1)  // Convert to 0-based index
                // log.infof("        Internal neighbor index: %d (looking for %d)", nei_idx, to_poly_idx)
            } else {
                // 0 means no neighbor, skip
                // if nei == 0 {
                //     log.infof("        Border edge (no neighbor)")
                // } else {
                //     log.infof("        Unknown neighbor type: 0x%x", nei)
                // }
                continue
            }

            if nei_idx == to_poly_idx {
                    // log.debugf("        MATCH FOUND! Extracting edge vertices...")

                    v0_idx := from_poly.verts[i]
                    v1_idx := from_poly.verts[(i + 1) % int(from_poly.vert_count)]

                    if int(v0_idx) >= len(from_tile.verts) || int(v1_idx) >= len(from_tile.verts) {
                        log.errorf("        INVALID vertex indices: v0=%d, v1=%d (max=%d)",
                                  v0_idx, v1_idx, len(from_tile.verts)-1)
                        continue
                    }

                    va := from_tile.verts[v0_idx]
                    vb := from_tile.verts[v1_idx]

                    // log.debugf("        va=%v, vb=%v", va, vb)

                    // Swap to match C++ behavior
                    left = vb
                    right = va
                    portal_type = 0

                    // log.debugf("        SUCCESS: Portal found via neighbor - left=%v, right=%v", left, right)
                    return left, right, portal_type, {.Success}
                }
        }

        // log.debugf("    No matching neighbors found in neighbor array")
    } else {
        log.infof("    Polygons in different tiles, neighbor references won't work")
    }

    log.errorf("  FAILURE: No portal found between polygons 0x%x and 0x%x", from, to)
    log.errorf("    Tried %d links, checked neighbor references", link_count)
    return {}, {}, 0, {.Invalid_Param}
}

// Analyze navmesh structure for debugging portal finding issues
analyze_navmesh_structure :: proc(nav_mesh: ^Nav_Mesh) {
    if nav_mesh == nil {
        log.errorf("analyze_navmesh_structure: null navmesh")
        return
    }

    log.infof("=== NAVMESH STRUCTURE ANALYSIS ===")
    log.infof("Max tiles: %d", nav_mesh.max_tiles)
    log.infof("Salt bits: %d, Tile bits: %d, Poly bits: %d",
             nav_mesh.salt_bits, nav_mesh.tile_bits, nav_mesh.poly_bits)

    active_tiles := 0
    total_polys := 0
    total_links := 0
    total_verts := 0

    for i in 0..<nav_mesh.max_tiles {
        tile := &nav_mesh.tiles[i]
        if tile.header == nil {
            continue
        }

        active_tiles += 1
        total_polys += int(tile.header.poly_count)
        total_links += len(tile.links)
        total_verts += len(tile.verts)

        log.infof("Tile %d: pos=(%d,%d), layer=%d", i, tile.header.x, tile.header.y, tile.header.layer)
        log.infof("  Polygons: %d, Vertices: %d, Links: %d",
                 tile.header.poly_count, len(tile.verts), len(tile.links))
        log.infof("  Bounds: min=%v, max=%v", tile.header.bmin, tile.header.bmax)

        // Analyze polygon connectivity
        connected_polys := 0
        isolated_polys := 0
        total_poly_links := 0

        for j in 0..<int(tile.header.poly_count) {
            poly := &tile.polys[j]
            poly_links := 0

            // Count links for this polygon
            link := poly.first_link
            max_link_checks := 50  // Safety limit
            link_checks := 0

            for link != recast.DT_NULL_LINK && link_checks < max_link_checks {
                if int(link) >= len(tile.links) {
                    log.errorf("    Polygon %d has invalid link index %d", j, link)
                    break
                }
                poly_links += 1
                link = tile.links[link].next
                link_checks += 1
            }

            if link_checks >= max_link_checks {
                log.errorf("    Polygon %d hit link safety limit, possible infinite loop", j)
            }

            total_poly_links += poly_links
            if poly_links > 0 {
                connected_polys += 1
            } else {
                isolated_polys += 1
            }
        }

        log.infof("  Connectivity: %d connected, %d isolated, avg %.1f links/poly",
                 connected_polys, isolated_polys, f32(total_poly_links) / f32(tile.header.poly_count))

        // Sample first few polygons for detailed analysis
        sample_count := min(3, int(tile.header.poly_count))
        log.infof("  Sample polygon details (first %d):", sample_count)

        for j in 0..<sample_count {
            poly := &tile.polys[j]
            poly_ref := encode_poly_id(nav_mesh, tile.salt, u32(i), u32(j))

            log.infof("    Poly %d (ref=0x%x): verts=%d, area=%d, type=%d",
                     j, poly_ref, poly.vert_count, poly_get_area(poly), poly_get_type(poly))

            // Log vertex positions
            for k in 0..<int(poly.vert_count) {
                vert_idx := poly.verts[k]
                if int(vert_idx) < len(tile.verts) {
                    pos := tile.verts[vert_idx]
                    log.infof("      v[%d]: idx=%d, pos=%v", k, vert_idx, pos)
                } else {
                    log.errorf("      v[%d]: INVALID idx=%d (max=%d)", k, vert_idx, len(tile.verts)-1)
                }
            }

            // Log neighbor information
            for k in 0..<int(poly.vert_count) {
                nei := poly.neis[k]
                log.infof("      neighbor[%d]: 0x%x", k, nei)
            }

            // Log link information
            link := poly.first_link
            link_num := 1
            max_link_details := 10

            for link != recast.DT_NULL_LINK && link_num <= max_link_details {
                if int(link) >= len(tile.links) {
                    log.errorf("      link %d: INVALID index %d", link_num, link)
                    break
                }

                link_info := &tile.links[link]
                log.infof("      link %d: edge=%d, ref=0x%x, side=%d",
                         link_num, link_info.edge, link_info.ref, link_info.side)

                link = link_info.next
                link_num += 1
            }

            if link_num > max_link_details {
                log.infof("      ... (more links not shown)")
            }
        }
    }

    log.infof("SUMMARY: %d active tiles, %d total polygons, %d total links, %d total vertices",
             active_tiles, total_polys, total_links, total_verts)
    log.infof("=== END NAVMESH ANALYSIS ===")
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
                             start_ref: recast.Poly_Ref, start_pos: [3]f32,
                             end_pos: [3]f32, filter: ^Query_Filter,
                             visited: []recast.Poly_Ref,
                             max_visited: i32) -> (result_pos: [3]f32, visited_count: i32, status: recast.Status) {

    visited_count = 0
    result_pos = start_pos

    if !is_valid_poly_ref(query.nav_mesh, start_ref) {
        return result_pos, visited_count, {.Invalid_Param}
    }

    tile, poly, tile_status := get_tile_and_poly_by_ref(query.nav_mesh, start_ref)
    if recast.status_failed(tile_status) {
        return result_pos, visited_count, tile_status
    }

    if max_visited > 0 {
        visited[0] = start_ref
        visited_count = 1
    }

    // If start equals end, we're done
    dir := end_pos - start_pos
    if linalg.length(dir) < 1e-6 {
        return result_pos, visited_count, {.Success}
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
                // log.warnf("Surface walk making insufficient progress after %d steps (%.3f < %.3f)", iter, step_progress, expected_min_progress)
                // Don't break immediately - try to continue
                if iter > 10 {  // Give it more chances
                    break
                }
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

            if neighbor_ref != recast.INVALID_POLY_REF {
                // Move to neighbor polygon
                cur_ref = neighbor_ref

                // Add to visited list
                if visited_count < max_visited {
                    visited[visited_count] = cur_ref
                    visited_count += 1
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

    result_pos = cur_pos
    return result_pos, visited_count, {.Success}
}

// Helper functions for surface movement

// Find closest point on polygon boundary (matches C++ closestPointOnPolyBoundary)
closest_point_on_poly_boundary_nav :: proc(query: ^Nav_Mesh_Query, ref: recast.Poly_Ref, pos: [3]f32) -> ([3]f32, recast.Status) {
    tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if recast.status_failed(status) || tile == nil || poly == nil {
        return pos, status
    }

    // Collect vertices
    verts := make([][3]f32, poly.vert_count)
    defer delete(verts)
    for i in 0..<int(poly.vert_count) {
        verts[i] = tile.verts[poly.verts[i]]
    }

    // Calculate edge distances and find closest point
    edge_dist := make([]f32, poly.vert_count)
    defer delete(edge_dist)
    edge_t := make([]f32, poly.vert_count)
    defer delete(edge_t)

    // Check distance to each edge
    for i in 0..<int(poly.vert_count) {
        j := (i + 1) % int(poly.vert_count)
        va := verts[i]
        vb := verts[j]

        // Calculate distance to edge
        dist_sqr, t := geometry.point_segment_distance2_2d(pos, va, vb)
        edge_dist[i] = dist_sqr
        edge_t[i] = t
    }

    // Check if point is inside polygon (using 2D test)
    inside := geometry.point_in_polygon_2d(pos, verts)

    if inside {
        // Point is inside, return the point itself
        return pos, {.Success}
    } else {
        // Point is outside, clamp to nearest edge
        min_dist := edge_dist[0]
        min_idx := 0
        for i in 1..<int(poly.vert_count) {
            if edge_dist[i] < min_dist {
                min_dist = edge_dist[i]
                min_idx = i
            }
        }

        // Interpolate along the closest edge
        j := (min_idx + 1) % int(poly.vert_count)
        va := verts[min_idx]
        vb := verts[j]
        result := linalg.lerp(va, vb, edge_t[min_idx])
        return result, {.Success}
    }
}

closest_point_on_poly :: proc(query: ^Nav_Mesh_Query, ref: recast.Poly_Ref, pos: [3]f32) -> [3]f32 {
    tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if recast.status_failed(status) {
        return pos
    }

    // Check if point is inside polygon first
    verts := make([][3]f32, poly.vert_count)
    defer delete(verts)
    for i in 0..<int(poly.vert_count) {
        verts[i] = tile.verts[poly.verts[i]]
    }

    if geometry.point_in_polygon_2d(pos, verts) {
        // Point is inside, return it with proper Y height
        avg_y := f32(0)
        for v in verts {
            avg_y += v.y
        }
        avg_y /= f32(len(verts))
        return {pos.x, avg_y, pos.z}
    }

    // Point is outside, find closest point on polygon edges
    closest := pos
    closest_dist_sqr := f32(math.F32_MAX)

    for i in 0..<int(poly.vert_count) {
        va := verts[i]
        vb := verts[(i + 1) % int(poly.vert_count)]

        // Find closest point on edge
        edge_closest := closest_point_on_segment_2d_funnel(pos, va, vb)

        dx := edge_closest.x - pos.x
        dz := edge_closest.z - pos.z
        dist_sqr := dx * dx + dz * dz

        if dist_sqr < closest_dist_sqr {
            closest_dist_sqr = dist_sqr
            closest = edge_closest
        }
    }

    return closest
}

// Helper for closest point on segment (local to funnel.odin)
closest_point_on_segment_2d_funnel :: proc(pos: [3]f32, a: [3]f32, b: [3]f32) -> [3]f32 {
    dx := b.x - a.x
    dz := b.z - a.z

    edge_len_sqr := dx * dx + dz * dz
    if edge_len_sqr < 1e-6 {
        return a
    }

    px := pos.x - a.x
    pz := pos.z - a.z
    t := (px * dx + pz * dz) / edge_len_sqr
    t = clamp(t, 0.0, 1.0)

    return {
        a.x + t * dx,
        a.y + t * (b.y - a.y),
        a.z + t * dz,
    }
}

point_in_polygon :: proc(query: ^Nav_Mesh_Query, ref: recast.Poly_Ref, pos: [3]f32) -> bool {
    tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if recast.status_failed(status) {
        return false
    }

    // Build polygon vertices
    verts := make([][3]f32, poly.vert_count)
    defer delete(verts)
    for i in 0..<int(poly.vert_count) {
        verts[i] = tile.verts[poly.verts[i]]
    }

    return geometry.point_in_polygon_2d(pos, verts)
}

find_neighbor_across_edge :: proc(query: ^Nav_Mesh_Query, ref: recast.Poly_Ref,
                                    start_pos: [3]f32, end_pos: [3]f32,
                                    filter: ^Query_Filter) -> (recast.Poly_Ref, bool) {

    tile, poly, status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if recast.status_failed(status) {
        return recast.INVALID_POLY_REF, false
    }

    // Check each edge for intersection with movement ray
    for i in 0..<int(poly.vert_count) {
        va := tile.verts[poly.verts[i]]
        vb := tile.verts[poly.verts[(i + 1) % int(poly.vert_count)]]

        // Check if movement ray intersects this edge
        if dt_intersect_segment_edge_2d(start_pos, end_pos, va, vb) {
            // Find neighbor across this edge
            link := poly.first_link
            link_iterations := 0
            max_link_iterations := 32  // Safety limit to prevent infinite loops

            for link != recast.DT_NULL_LINK && link_iterations < max_link_iterations {
                link_iterations += 1

                if get_link_edge(tile, link) == u8(i) {
                    neighbor_ref := get_link_poly_ref(tile, link)
                    if neighbor_ref != recast.INVALID_POLY_REF {
                        neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                        if recast.status_succeeded(neighbor_status) &&
                           query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {
                            return neighbor_ref, false
                        }
                    }
                }
                link = get_next_link(tile, link)
            }

            // No valid neighbor, hit wall
            return recast.INVALID_POLY_REF, true
        }
    }

    return recast.INVALID_POLY_REF, false
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
