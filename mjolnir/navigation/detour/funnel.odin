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

    log.infof("find_straight_path: ENTERED - start_pos=%v, end_pos=%v, path_count=%d", start_pos, end_pos, path_count)
    log.infof("  len(path)=%d, len(straight_path)=%d, max_straight_path=%d", len(path), len(straight_path), max_straight_path)

    // Validate input parameters
    if query == nil || query.nav_mesh == nil {
        log.errorf("find_straight_path: Invalid query or navmesh")
        return {.Invalid_Param}, straight_path_count
    }

    if path_count == 0 {
        log.errorf("find_straight_path: Empty path")
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
        log.infof("find_straight_path: Added start point %v", start_pos)
    } else {
        stat |= {.Buffer_Too_Small}
    }

    log.infof("find_straight_path: Starting portal loop for %d polygons", path_count)
    
    // Special case for single polygon path
    if path_count == 1 {
        log.info("find_straight_path: Single polygon path detected, skipping funnel algorithm")
        // For a single polygon, the path is just start -> end
        // Skip the portal processing
    } else {

    // Process path corridors
    MAX_ITERATIONS :: 10000
    iteration_count := i32(0)
    
    for i := i32(0); i < path_count; i += 1 {  // C++ style: increment in for statement
        iteration_count += 1
        if iteration_count > MAX_ITERATIONS {
            log.errorf("find_straight_path: Infinite loop detected after %d iterations! i=%d, apex_index=%d, path_count=%d", 
                      iteration_count, i, apex_index, path_count)
            break
        }
        
        if iteration_count % 1000 == 0 {
            log.warnf("find_straight_path: High iteration count %d, i=%d, apex=%d", iteration_count, i, apex_index)
        }
        
        if iteration_count > 9990 {  // Log details near the end
            log.debugf("Iteration %d: i=%d, apex=%d, left=%d, right=%d", 
                      iteration_count, i, apex_index, left_index, right_index)
        }
        
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
            
            // Check if portal is degenerate
            if dt_vequal(left, right) && i > 0 {
                log.debugf("WARNING: Degenerate portal at i=%d, left==right=%v", i, left)
            }
            if nav_recast.status_failed(portal_status) {
                // Failed to get portal - use fallback
                log.warnf("Failed to get portal between poly 0x%x and 0x%x (indices %d->%d), using fallback", 
                          path[i], path[i+1], i, i+1)
                
                // Always use polygon centroids as fallback
                from_tile, from_poly, _ := get_tile_and_poly_by_ref(query.nav_mesh, path[i])
                to_tile, to_poly, _ := get_tile_and_poly_by_ref(query.nav_mesh, path[i+1])
                
                if from_tile != nil && from_poly != nil && to_tile != nil && to_poly != nil {
                    // Use centroids as a fallback portal
                    from_center := calc_poly_center(from_tile, from_poly)
                    to_center := calc_poly_center(to_tile, to_poly)
                    
                    // Create a wider portal perpendicular to the direction
                    mid := linalg.mix(from_center, to_center, 0.5)
                    dir := to_center - from_center
                    dir_len := linalg.length(dir)
                    if dir_len > 0.001 {
                        dir = dir / dir_len
                        perp := [3]f32{-dir.z, dir.y, dir.x} * 2.0  // Wider portal
                        left = mid + perp
                        right = mid - perp
                    } else {
                        // Polygons are at same position, use small offset
                        left = mid + [3]f32{0.1, 0, 0.1}
                        right = mid - [3]f32{0.1, 0, 0.1}
                    }
                    from_type = 0
                    
                    log.infof("Using centroid-based fallback portal: left=%v, right=%v", left, right)
                } else {
                    // Can't get polygon info, use simple interpolation
                    if i > 0 {
                        // Interpolate from previous position toward end
                        t := f32(i) / f32(path_count - 1)
                        mid := portal_apex + (end_pos - portal_apex) * t
                        left = mid + [3]f32{0.5, 0, 0.5}
                        right = mid - [3]f32{0.5, 0, 0.5}
                        from_type = 0
                        log.warnf("Using interpolated fallback portal at t=%.2f", t)
                    } else {
                        // First portal, skip
                        continue
                    }
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
        
        // Check right vertex
        tri_area_right := geometry.vec2f_perp(portal_apex, portal_right, right)
        
        if tri_area_right <= 0.0 {
            // Check if apex equals portal_right or if right is on correct side of left edge
            if dt_vequal(portal_apex, portal_right) || geometry.vec2f_perp(portal_apex, portal_left, right) > 0.0 {
                // Tighten the funnel
                portal_right = right
                right_poly_type = (i + 1 == path_count) ? to_type : 0
                right_index = i
                log.debugf("Updated right_index to %d at i=%d", right_index, i)
            } else {
                // Right vertex crossed left edge, add left vertex and restart scan
                log.debugf("Right crossed left at i=%d: adding left vertex, left_index=%d", i, left_index)
                
                // Check if we're about to add a duplicate point
                add_point := true
                if n_straight_path > 0 {
                    last_pos := straight_path[n_straight_path-1].pos
                    if dt_vequal(last_pos, portal_left) {
                        log.debugf("Skipping duplicate point at position %v", portal_left)
                        add_point = false
                    }
                }
                
                if add_point && n_straight_path < max_straight_path {
                    // Append vertex
                    straight_path[n_straight_path] = {
                        pos = portal_left,
                        flags = left_poly_type,
                        ref = path[left_index],
                    }
                    n_straight_path += 1
                    log.debugf("Added point %d at position %v", n_straight_path-1, portal_left)
                } else if add_point {
                    stat |= {.Buffer_Too_Small}
                }
                
                // Only restart if we actually added a point (made progress)
                if add_point {
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
                    
                    // Restart scan from new apex
                    // Set to apex_index - 1 because the loop will increment it
                    log.debugf("Restarting from apex: apex_index=%d (was at i=%d), setting i=%d", 
                              apex_index, i, apex_index - 1)
                    i = apex_index - 1  // Will be incremented to apex_index by the for loop
                    continue  // Continue from the top of the loop with new i value
                } else {
                    // Skip this portal and continue to next
                    log.debugf("Not restarting - no progress made, continuing to next portal")
                }
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
                log.debugf("Updated left_index to %d at i=%d", left_index, i)
            } else {
                // Left vertex crossed right edge, add right vertex and restart scan
                log.debugf("Left crossed right at i=%d: adding right vertex, right_index=%d", i, right_index)
                
                // Check if we're about to add a duplicate point
                add_point := true
                if n_straight_path > 0 {
                    last_pos := straight_path[n_straight_path-1].pos
                    if dt_vequal(last_pos, portal_right) {
                        log.debugf("Skipping duplicate point at position %v", portal_right)
                        add_point = false
                    }
                }
                
                if add_point && n_straight_path < max_straight_path {
                    // Append vertex
                    straight_path[n_straight_path] = {
                        pos = portal_right,
                        flags = right_poly_type,
                        ref = path[right_index],
                    }
                    n_straight_path += 1
                    log.debugf("Added point %d at position %v", n_straight_path-1, portal_right)
                } else if add_point {
                    stat |= {.Buffer_Too_Small}
                }
                
                // Only restart if we actually added a point (made progress)
                if add_point {
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
                    
                    // Restart scan from new apex
                    // Set to apex_index - 1 because the loop will increment it
                    log.debugf("Restarting from apex: apex_index=%d (was at i=%d), setting i=%d", 
                              apex_index, i, apex_index - 1)
                    i = apex_index - 1  // Will be incremented to apex_index by the for loop
                    continue  // Continue from the top of the loop with new i value
                } else {
                    // Skip this portal and continue to next
                    log.debugf("Not restarting - no progress made, continuing to next portal")
                }
            }
        }
    }
    }  // End of else block for single polygon special case

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

    log.infof("find_straight_path: result count=%d, status=%v", straight_path_count, stat)

    // Return success if no errors
    if stat == {} {
        stat |= {.Success}
    }

    return stat, straight_path_count
}

// Get portal points between two adjacent polygons
get_portal_points :: proc(query: ^Nav_Mesh_Query, from: nav_recast.Poly_Ref, to: nav_recast.Poly_Ref,
                            left: ^[3]f32, right: ^[3]f32, portal_type: ^u8) -> nav_recast.Status {

    // log.debugf("get_portal_points: from=0x%x to=0x%x", from, to)

    from_tile, from_poly, from_status := get_tile_and_poly_by_ref(query.nav_mesh, from)
    if nav_recast.status_failed(from_status) {
        log.errorf("  FAILED: Could not get from polygon 0x%x, status=%v", from, from_status)
        return from_status
    }

    to_tile, to_poly, to_status := get_tile_and_poly_by_ref(query.nav_mesh, to)
    if nav_recast.status_failed(to_status) {
        log.errorf("  FAILED: Could not get to polygon 0x%x, status=%v", to, to_status)
        return to_status
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
    // log.debugf("  METHOD 1: Searching via links...")
    link := from_poly.first_link
    link_count := 0
    max_links_to_check := 20  // Safety limit
    
    for link != nav_recast.DT_NULL_LINK && link_count < max_links_to_check {
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
            left^ = v1_pos
            right^ = v0_pos
            portal_type^ = 0

            // log.debugf("      SUCCESS: Portal found via link - left=%v, right=%v", left^, right^)
            return {.Success}
        }
        
        link = link_info.next
    }
    
    if link_count >= max_links_to_check {
        log.errorf("    Hit link traversal safety limit (%d), possible infinite loop", max_links_to_check)
    }
    
    log.infof("    Links checked: %d, no match found", link_count)
    
    // Fallback: check neighbor references
    log.infof("  METHOD 2: Checking neighbor references...")
    log.infof("    Same tile check: from_tile=%d, to_tile=%d", from_tile_idx, to_tile_idx)
    
    // Check if they're in the same tile (neighbor references only work within tile)
    if from_tile_idx == to_tile_idx {
        log.infof("    Polygons are in same tile, checking neighbor array...")
        
        for i in 0..<int(from_poly.vert_count) {
            nei := from_poly.neis[i]
            log.infof("      Edge %d: neighbor=0x%x", i, nei)
            
            // Check internal edge connection (1-based index)
            if nei > 0 && nei <= 0x3f {  // Internal edge marker
                nei_idx := u32(nei - 1)  // Convert to 0-based index
                log.infof("        Internal neighbor index: %d (looking for %d)", nei_idx, to_poly_idx)
                
                if nei_idx == to_poly_idx {
                    log.infof("        MATCH FOUND! Extracting edge vertices...")
                    
                    v0_idx := from_poly.verts[i]
                    v1_idx := from_poly.verts[(i + 1) % int(from_poly.vert_count)]
                    
                    if int(v0_idx) >= len(from_tile.verts) || int(v1_idx) >= len(from_tile.verts) {
                        log.errorf("        INVALID vertex indices: v0=%d, v1=%d (max=%d)", 
                                  v0_idx, v1_idx, len(from_tile.verts)-1)
                        continue
                    }
                    
                    va := from_tile.verts[v0_idx]
                    vb := from_tile.verts[v1_idx]

                    log.infof("        va=%v, vb=%v", va, vb)

                    // Swap to match C++ behavior
                    left^ = vb
                    right^ = va
                    portal_type^ = 0

                    log.infof("        SUCCESS: Portal found via neighbor - left=%v, right=%v", left^, right^)
                    return {.Success}
                }
            } else if nei == 0 {
                log.infof("        Border edge (no neighbor)")
            } else {
                log.infof("        External neighbor or special case: 0x%x", nei)
            }
        }
        
        log.infof("    No matching neighbors found in neighbor array")
    } else {
        log.infof("    Polygons in different tiles, neighbor references won't work")
    }

    log.errorf("  FAILURE: No portal found between polygons 0x%x and 0x%x", from, to)
    log.errorf("    Tried %d links, checked neighbor references", link_count)
    return {.Invalid_Param}
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
            
            for link != nav_recast.DT_NULL_LINK && link_checks < max_link_checks {
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
            
            for link != nav_recast.DT_NULL_LINK && link_num <= max_link_details {
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
            link := poly.first_link
            link_iterations := 0
            max_link_iterations := 32  // Safety limit to prevent infinite loops
            
            for link != nav_recast.DT_NULL_LINK && link_iterations < max_link_iterations {
                link_iterations += 1
                
                if get_link_edge(tile, link) == u8(i) {
                    neighbor_ref := get_link_poly_ref(tile, link)
                    if neighbor_ref != nav_recast.INVALID_POLY_REF {
                        neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                        if nav_recast.status_succeeded(neighbor_status) &&
                           query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {
                            return neighbor_ref, false
                        }
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