package navigation_detour

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:log"
import nav_recast "../recast"
import nav ".."

// Find nearest polygon to given position
dt_find_nearest_poly :: proc(query: ^Dt_Nav_Mesh_Query, center: [3]f32, half_extents: [3]f32,
                            filter: ^Dt_Query_Filter, nearest_ref: ^nav_recast.Poly_Ref,
                            nearest_pt: ^[3]f32) -> nav_recast.Status {

    nearest_ref^ = nav_recast.INVALID_POLY_REF
    nearest_pt^ = center

    // Calculate query bounds
    bmin := center - half_extents
    bmax := center + half_extents

    // Find tiles that overlap query region
    tx0, ty0 := dt_calc_tile_loc_simple(query.nav_mesh, bmin)
    tx1, ty1 := dt_calc_tile_loc_simple(query.nav_mesh, bmax)
    log.infof("dt_find_nearest_poly: Searching tiles (%d,%d) to (%d,%d) for position %v", tx0, ty0, tx1, ty1, center)

    nearest_dist_sqr := f32(math.F32_MAX)

    // Search tiles
    for ty in ty0..=ty1 {
        for tx in tx0..=tx1 {
            tile := dt_get_tile_at(query.nav_mesh, tx, ty, 0)
            if tile == nil || tile.header == nil {
                log.infof("  No tile at (%d,%d)", tx, ty)
                continue
            }
            log.infof("  Found tile at (%d,%d) with %d polygons", tx, ty, tile.header.poly_count)

            // Query polygons in tile using temp allocator
            poly_refs := make([]nav_recast.Poly_Ref, 128, context.temp_allocator)
            poly_count := dt_query_polygons_in_tile(query.nav_mesh, tile, bmin, bmax, poly_refs, 128)
            log.infof("  Query returned %d polygons", poly_count)

            for i in 0..<poly_count {
                ref := poly_refs[i]

                // Check filter
                tile_poly, poly, poly_status := dt_get_tile_and_poly_by_ref(query.nav_mesh, ref)
                if nav_recast.status_failed(poly_status) {
                    continue
                }

                if !dt_query_filter_pass_filter(filter, ref, tile_poly, poly) {
                    continue
                }

                // Find closest point on polygon
                closest_pt, inside := dt_closest_point_on_polygon(tile_poly, poly, center)

                // Calculate distance
                dist_sqr := linalg.length2(center - closest_pt)

                // Check if this is the nearest so far
                if dist_sqr < nearest_dist_sqr {
                    nearest_dist_sqr = dist_sqr
                    nearest_ref^ = ref
                    nearest_pt^ = closest_pt
                }
            }
        }
    }

    return {.Success}
}

// Query polygons within bounding box
dt_query_polygons :: proc(query: ^Dt_Nav_Mesh_Query, center: [3]f32, half_extents: [3]f32,
                         filter: ^Dt_Query_Filter, polys: []nav_recast.Poly_Ref,
                         poly_count: ^i32, max_polys: i32) -> nav_recast.Status {

    poly_count^ = 0

    // Calculate query bounds
    bmin := center - half_extents
    bmax := center + half_extents

    // Find tiles that overlap query region
    tx0, ty0 := dt_calc_tile_loc_simple(query.nav_mesh, bmin)
    tx1, ty1 := dt_calc_tile_loc_simple(query.nav_mesh, bmax)

    // Search tiles
    for ty in ty0..=ty1 {
        for tx in tx0..=tx1 {
            tile := dt_get_tile_at(query.nav_mesh, tx, ty, 0)
            if tile == nil || tile.header == nil {
                log.infof("  No tile at (%d,%d)", tx, ty)
                continue
            }
            log.infof("  Found tile at (%d,%d) with %d polygons", tx, ty, tile.header.poly_count)

            // Query polygons in tile
            remaining := max_polys - poly_count^
            if remaining <= 0 {
                break
            }

            tile_poly_count := dt_query_polygons_in_tile(query.nav_mesh, tile, bmin, bmax,
                                                        polys[poly_count^:], remaining)

            // Apply filter
            filtered_count := i32(0)
            for i in 0..<tile_poly_count {
                ref := polys[poly_count^ + i]
                tile_poly, poly, poly_status := dt_get_tile_and_poly_by_ref(query.nav_mesh, ref)
                if nav_recast.status_succeeded(poly_status) &&
                   dt_query_filter_pass_filter(filter, ref, tile_poly, poly) {

                    polys[poly_count^ + filtered_count] = ref
                    filtered_count += 1
                }
            }

            poly_count^ += filtered_count
        }
    }

    return {.Success}
}

// Raycast along navigation mesh surface
dt_raycast :: proc(query: ^Dt_Nav_Mesh_Query, start_ref: nav_recast.Poly_Ref, start_pos: [3]f32,
                  end_pos: [3]f32, filter: ^Dt_Query_Filter, options: u32,
                  hit: ^Dt_Raycast_Hit, path: []nav_recast.Poly_Ref, path_count: ^i32,
                  max_path: i32) -> nav_recast.Status {

    path_count^ = 0
    hit.t = math.F32_MAX
    hit.path_cost = 0
    hit.hit_edge_index = -1

    if !dt_is_valid_poly_ref(query.nav_mesh, start_ref) {
        return {.Invalid_Param}
    }

    cur_ref := start_ref
    cur_pos := start_pos
    dir := end_pos - start_pos
    ray_len := linalg.length(dir)

    if ray_len < 1e-6 {
        return {.Success}
    }

    ray_dir := dir / ray_len

    // Add start polygon to path
    if max_path > 0 {
        path[0] = start_ref
        path_count^ = 1
    }

    cur_t := f32(0)

    for cur_t < ray_len {
        // Get current polygon
        tile, poly, poly_status := dt_get_tile_and_poly_by_ref(query.nav_mesh, cur_ref)
        if nav_recast.status_failed(poly_status) {
            break
        }

        // Find intersection with polygon edges
        next_ref := nav_recast.INVALID_POLY_REF
        next_t := ray_len
        hit_edge := -1

        for i in 0..<int(poly.vert_count) {
            va := tile.verts[poly.verts[i]]
            vb := tile.verts[poly.verts[(i + 1) % int(poly.vert_count)]]

            // Test ray intersection with edge
            edge_t, intersects := dt_intersect_ray_segment_2d(cur_pos, ray_dir, va, vb)

            if intersects && edge_t > cur_t && edge_t < next_t {
                // Check if there's a neighbor across this edge
                link := dt_get_first_link(tile, i32(cur_ref & 0xffff))
                neighbor_found := false

                for link != nav_recast.DT_NULL_LINK {
                    neighbor_ref := dt_get_link_poly_ref(tile, link)
                    if neighbor_ref != nav_recast.INVALID_POLY_REF {
                        neighbor_tile, neighbor_poly, neighbor_status := dt_get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                        if nav_recast.status_succeeded(neighbor_status) &&
                           dt_query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {
                            next_ref = neighbor_ref
                            next_t = edge_t
                            neighbor_found = true
                            break
                        }
                    }
                    link = dt_get_next_link(tile, link)
                }

                if !neighbor_found {
                    // Hit a wall
                    hit.t = edge_t
                    hit.hit_edge_index = i32(i)

                    // Calculate hit normal
                    edge_dir := vb - va
                    hit.hit_normal = {edge_dir.z, 0, -edge_dir.x} // Perpendicular in 2D
                    hit.hit_normal = linalg.normalize(hit.hit_normal)

                    return {.Success}
                }
            }
        }

        if next_ref == nav_recast.INVALID_POLY_REF {
            // No more intersections, ray ends in current polygon
            break
        }

        // Move to next polygon
        cur_ref = next_ref
        cur_t = next_t
        cur_pos = start_pos + ray_dir * cur_t

        // Add to path
        if path_count^ < max_path {
            path[path_count^] = cur_ref
            path_count^ += 1
        }

        // Calculate cost if requested
        if (options & nav_recast.DT_RAYCAST_USE_COSTS) != 0 {
            prev_cost := hit.path_cost
            segment_cost := dt_query_filter_get_cost(filter,
                                                    start_pos + ray_dir * (cur_t - 0.01),
                                                    cur_pos,
                                                    nav_recast.INVALID_POLY_REF, nil, nil,
                                                    cur_ref, tile, poly,
                                                    nav_recast.INVALID_POLY_REF, nil, nil)
            hit.path_cost = prev_cost + segment_cost
        }
    }

    // Ray completed without hitting walls
    hit.t = ray_len
    return {.Success}
}

// Find random point on navigation mesh
dt_find_random_point :: proc(query: ^Dt_Nav_Mesh_Query, filter: ^Dt_Query_Filter,
                            random_ref: ^nav_recast.Poly_Ref, random_pt: ^[3]f32) -> nav_recast.Status {

    random_ref^ = nav_recast.INVALID_POLY_REF
    random_pt^ = {0, 0, 0}

    // For simplicity, find first walkable polygon
    // A full implementation would properly sample based on polygon areas

    for i in 0..<query.nav_mesh.max_tiles {
        tile := &query.nav_mesh.tiles[i]
        if tile.header == nil {
            continue
        }

        for j in 0..<int(tile.header.poly_count) {
            poly := &tile.polys[j]
            ref := dt_encode_poly_id(query.nav_mesh, tile.salt, u32(i), u32(j))

            if dt_query_filter_pass_filter(filter, ref, tile, poly) {
                random_ref^ = ref
                random_pt^ = dt_calc_poly_center(tile, poly)
                return {.Success}
            }
        }
    }

    return {.Invalid_Param}
}

// Find random point around given position
dt_find_random_point_around_circle :: proc(query: ^Dt_Nav_Mesh_Query, start_ref: nav_recast.Poly_Ref,
                                          start_pos: [3]f32, max_radius: f32, filter: ^Dt_Query_Filter,
                                          random_ref: ^nav_recast.Poly_Ref, random_pt: ^[3]f32) -> nav_recast.Status {

    random_ref^ = nav_recast.INVALID_POLY_REF
    random_pt^ = start_pos

    if !dt_is_valid_poly_ref(query.nav_mesh, start_ref) {
        return {.Invalid_Param}
    }

    // Simple implementation: sample random point in circle and project to mesh
    angle := math.PI * 2.0 * 0.5 // Use fixed value for deterministic results
    radius := max_radius * 0.7   // Use 70% of max radius

    offset := [3]f32{
        f32(math.cos(angle)) * radius,
        0,
        f32(math.sin(angle)) * radius,
    }

    target := start_pos + offset

    // Find nearest polygon to target
    half_extents := [3]f32{max_radius, max_radius, max_radius}
    return dt_find_nearest_poly(query, target, half_extents, filter, random_ref, random_pt)
}

// Helper functions

dt_query_polygons_in_tile :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile, qmin: [3]f32, qmax: [3]f32,
                                 polys: []nav_recast.Poly_Ref, max_polys: i32) -> i32 {

    // For now, always use brute force to verify the BV tree issue
    log.infof("    Using brute force for polygon query")

    // Fallback: test all polygons
    count := i32(0)
    base := dt_get_poly_ref_base(nav_mesh, tile)

    for i in 0..<int(tile.header.poly_count) {
        poly := &tile.polys[i]

        // Calculate polygon bounds
        poly_min := [3]f32{math.F32_MAX, math.F32_MAX, math.F32_MAX}
        poly_max := [3]f32{-math.F32_MAX, -math.F32_MAX, -math.F32_MAX}

        for j in 0..<int(poly.vert_count) {
            // Validate vertex index to prevent array bounds errors
            vertex_idx := poly.verts[j]
            if vertex_idx >= u16(len(tile.verts)) {
                log.warnf("Polygon %d vertex %d has invalid index %d (max %d), skipping polygon",
                         i, j, vertex_idx, len(tile.verts) - 1)
                break
            }

            vert := tile.verts[vertex_idx]
            poly_min = linalg.min(poly_min, vert)
            poly_max = linalg.max(poly_max, vert)
        }

        // Test overlap
        overlap := dt_overlap_bounds(qmin, qmax, poly_min, poly_max)
        if i < 5 { // Debug first few polygons
            log.infof("    Polygon %d: bounds %v-%v, query %v-%v, overlap=%t", 
                      i, poly_min, poly_max, qmin, qmax, overlap)
        }
        if overlap {
            if count < max_polys {
                polys[count] = base | nav_recast.Poly_Ref(i)
                count += 1
            }
        }
    }

    return count
}

dt_query_polygons_in_tile_bv :: proc(nav_mesh: ^Dt_Nav_Mesh, tile: ^Dt_Mesh_Tile, qmin: [3]f32, qmax: [3]f32,
                                    polys: []nav_recast.Poly_Ref, max_polys: i32) -> i32 {
    // BV tree traversal for spatial queries
    count := i32(0)
    base := dt_get_poly_ref_base(nav_mesh, tile)

    // Convert query bounds to quantized space
    factor := tile.header.bv_quant_factor
    iqmin := nav_recast.quantize_float(qmin - tile.header.bmin, factor)
    iqmax := nav_recast.quantize_float(qmax - tile.header.bmin, factor)
    log.infof("    BV tree: qmin=%v qmax=%v, tile.bmin=%v, bmax=%v, factor=%v", qmin, qmax, tile.header.bmin, tile.header.bmax, factor)
    log.infof("    BV tree: iqmin=%v iqmax=%v", iqmin, iqmax)
    
    // Debug: Show some polygon vertices
    if len(tile.verts) > 0 && len(tile.polys) > 0 {
        log.infof("    First polygon has %d verts, showing first vertex:", tile.polys[0].vert_count)
        if tile.polys[0].vert_count > 0 {
            vert_idx := tile.polys[0].verts[0]
            if int(vert_idx) < len(tile.verts) {
                v := tile.verts[vert_idx]
                log.infof("      Vertex %d: world pos %v", vert_idx, v)
            }
        }
    }

    // Traverse BV tree
    stack := make([]i32, 32, context.temp_allocator)
    stack_size := 0

    if len(tile.bv_tree) > 0 {
        stack[0] = 0
        stack_size = 1
    }

    for stack_size > 0 {
        node_index := stack[stack_size - 1]
        stack_size -= 1

        if node_index < 0 || node_index >= i32(len(tile.bv_tree)) {
            continue
        }

        node := &tile.bv_tree[node_index]

        // Convert node bounds to i32
        node_min := [3]i32{i32(node.bmin[0]), i32(node.bmin[1]), i32(node.bmin[2])}
        node_max := [3]i32{i32(node.bmax[0]), i32(node.bmax[1]), i32(node.bmax[2])}

        overlap := nav_recast.overlap_quantized_bounds(iqmin, iqmax, node_min, node_max)
        if node_index < 10 {
            log.infof("      BV node %d: bounds %v-%v, overlap=%t, leaf=%t", 
                      node_index, node_min, node_max, overlap, node.i >= 0)
        }
        
        if !overlap {
            continue
        }

        if node.i >= 0 {
            // Leaf node, add polygon
            if count < max_polys {
                polys[count] = base | nav_recast.Poly_Ref(node.i)
                count += 1
                if node_index < 5 {
                    log.infof("      Added polygon %d from leaf node %d", node.i, node_index)
                }
            }
        } else {
            // Internal node, add children to stack
            child1 := (-node.i) - 1
            child2 := child1 + 1
            
            if node_index < 5 {
                log.infof("      Internal node %d: children %d, %d", node_index, child1, child2)
            }

            if stack_size < 30 && child1 >= 0 && child1 < i32(len(tile.bv_tree)) {
                stack[stack_size] = child1
                stack_size += 1

                if stack_size < 30 && child2 >= 0 && child2 < i32(len(tile.bv_tree)) {
                    stack[stack_size] = child2
                    stack_size += 1
                }
            }
        }
    }

    return count
}

dt_closest_point_on_polygon :: proc(tile: ^Dt_Mesh_Tile, poly: ^Dt_Poly, pos: [3]f32) -> ([3]f32, bool) {
    // For simplicity, use polygon center
    // A full implementation would project to the actual polygon surface
    center := dt_calc_poly_center(tile, poly)

    // Check if point is inside using 2D test
    verts := make([][3]f32, poly.vert_count, context.temp_allocator)
    for i in 0..<int(poly.vert_count) {
        verts[i] = tile.verts[poly.verts[i]]
    }

    inside := nav_recast.point_in_polygon_2d(pos, verts)

    if inside {
        return pos, true
    } else {
        return center, false
    }
}

dt_overlap_bounds :: proc(amin: [3]f32, amax: [3]f32, bmin: [3]f32, bmax: [3]f32) -> bool {
    return amin[0] <= bmax[0] && amax[0] >= bmin[0] &&
           amin[1] <= bmax[1] && amax[1] >= bmin[1] &&
           amin[2] <= bmax[2] && amax[2] >= bmin[2]
}

dt_intersect_ray_segment_2d :: proc(ray_start: [3]f32, ray_dir: [3]f32, seg_a: [3]f32, seg_b: [3]f32) -> (f32, bool) {
    // 2D ray-segment intersection in XZ plane
    dx := seg_b.x - seg_a.x
    dz := seg_b.z - seg_a.z

    denominator := ray_dir.x * dz - ray_dir.z * dx
    if math.abs(denominator) < 1e-6 {
        return 0, false // Parallel
    }

    sx := ray_start.x - seg_a.x
    sz := ray_start.z - seg_a.z

    t := (dx * sz - dz * sx) / denominator
    u := (ray_dir.x * sz - ray_dir.z * sx) / denominator

    if t >= 0 && u >= 0 && u <= 1 {
        return t, true
    }

    return 0, false
}
