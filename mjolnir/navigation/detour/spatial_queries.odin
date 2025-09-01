package navigation_detour

import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:log"
import recast "../recast"
import geometry "../../geometry"

// Find nearest polygon to given position
find_nearest_poly :: proc(query: ^Nav_Mesh_Query, center: [3]f32, half_extents: [3]f32, filter: ^Query_Filter) ->
    (status: recast.Status, nearest_ref: recast.Poly_Ref, nearest_pt: [3]f32) {
    nearest_ref = recast.INVALID_POLY_REF
    nearest_pt = center
    log.infof("find_nearest_poly: center=%v, half_extents=%v", center, half_extents)
    // Calculate query bounds
    bmin := center - half_extents
    bmax := center + half_extents
    // Find tiles that overlap query region
    tx0, ty0 := calc_tile_loc_simple(query.nav_mesh, bmin)
    tx1, ty1 := calc_tile_loc_simple(query.nav_mesh, bmax)
    log.infof("find_nearest_poly: Searching tiles (%d,%d) to (%d,%d) for position %v", tx0, ty0, tx1, ty1, center)
    nearest_dist_sqr := f32(math.F32_MAX)
    total_tiles_checked := 0
    total_polys_checked := 0
    // Search tiles
    for ty in ty0..=ty1 {
        for tx in tx0..=tx1 {
            tile := get_tile_at(query.nav_mesh, tx, ty, 0)
            total_tiles_checked += 1
            if tile == nil || tile.header == nil {
                log.infof("  No tile at (%d,%d)", tx, ty)
                continue
            }
            log.infof("  Found tile at (%d,%d) with %d polygons", tx, ty, tile.header.poly_count)

            // Query polygons in tile using temp allocator
            poly_refs := make([]recast.Poly_Ref, 128)
            defer delete(poly_refs)
            poly_count := query_polygons_in_tile(query.nav_mesh, tile, bmin, bmax, poly_refs, 128)
            log.infof("  Query returned %d polygons", poly_count)
            total_polys_checked += int(poly_count)

            for i in 0..<poly_count {
                ref := poly_refs[i]

                // Check filter
                tile_poly, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
                if recast.status_failed(poly_status) {
                    continue
                }

                if !query_filter_pass_filter(filter, ref, tile_poly, poly) {
                    continue
                }

                // Find closest point on polygon
                closest_pt, inside := closest_point_on_polygon(tile_poly, poly, center)

                // Calculate distance
                dist_sqr := linalg.length2(center - closest_pt)

                // Debug logging for start position case
                when ODIN_DEBUG {
                    if math.abs(center[0] - (-3.0)) < 0.1 && math.abs(center[2] - (-3.0)) < 0.1 {
                        _, _, poly_idx := decode_poly_id(query.nav_mesh, ref)
                        log.infof("  Poly %d (ref=0x%x): closest_pt=(%.2f,%.2f,%.2f) dist_sqr=%.2f inside=%v",
                                 poly_idx, ref, closest_pt[0], closest_pt[1], closest_pt[2], dist_sqr, inside)
                    }
                }

                // Check if this is the nearest so far
                if dist_sqr < nearest_dist_sqr {
                    nearest_dist_sqr = dist_sqr
                    nearest_ref = ref
                    nearest_pt = closest_pt
                }
            }
        }
    }

    log.infof("find_nearest_poly: Checked %d tiles, %d polygons total. nearest_ref=0x%x, dist_sqr=%f",
              total_tiles_checked, total_polys_checked, nearest_ref, nearest_dist_sqr)
    // Return success even if no polygon was found - caller can check if nearest_ref is valid
    return {.Success}, nearest_ref, nearest_pt
}

// Query polygons within bounding box
query_polygons :: proc(query: ^Nav_Mesh_Query, center: [3]f32, half_extents: [3]f32,
                         filter: ^Query_Filter, polys: []recast.Poly_Ref) -> (status: recast.Status, poly_count: i32) {

    poly_count = 0

    // Calculate query bounds
    bmin := center - half_extents
    bmax := center + half_extents

    // Find tiles that overlap query region
    tx0, ty0 := calc_tile_loc_simple(query.nav_mesh, bmin)
    tx1, ty1 := calc_tile_loc_simple(query.nav_mesh, bmax)

    // Search tiles
    for ty in ty0..=ty1 {
        for tx in tx0..=tx1 {
            tile := get_tile_at(query.nav_mesh, tx, ty, 0)
            if tile == nil || tile.header == nil {
                // log.infof("  No tile at (%d,%d)", tx, ty)
                continue
            }
            // log.infof("  Found tile at (%d,%d) with %d polygons", tx, ty, tile.header.poly_count)

            // Query polygons in tile
            remaining := i32(len(polys)) - poly_count
            if remaining <= 0 {
                break
            }

            tile_poly_count := query_polygons_in_tile(query.nav_mesh, tile, bmin, bmax,
                                                        polys[poly_count:], remaining)

            // Apply filter
            filtered_count := i32(0)
            for i in 0..<tile_poly_count {
                ref := polys[poly_count + i]
                tile_poly, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
                if recast.status_succeeded(poly_status) &&
                   query_filter_pass_filter(filter, ref, tile_poly, poly) {

                    polys[poly_count + filtered_count] = ref
                    filtered_count += 1
                }
            }

            poly_count += filtered_count
        }
    }

    return {.Success}, poly_count
}

// Raycast along navigation mesh surface
raycast :: proc(query: ^Nav_Mesh_Query, start_ref: recast.Poly_Ref, start_pos, end_pos: [3]f32, filter: ^Query_Filter, options: u32,
                  path: []recast.Poly_Ref, max_path: i32) -> (status: recast.Status,
                                                                   hit: Raycast_Hit,
                                                                   path_count: i32) {

    path_count = 0
    hit.t = math.F32_MAX
    hit.path_cost = 0
    hit.hit_edge_index = -1

    if !is_valid_poly_ref(query.nav_mesh, start_ref) {
        return {.Invalid_Param}, hit, 0
    }

    cur_ref := start_ref
    cur_pos := start_pos
    dir := end_pos - start_pos
    ray_len := linalg.length(dir)

    if ray_len < 1e-6 {
        // Zero-length ray should have t=0
        hit.t = 0.0
        return {.Success}, hit, path_count
    }

    ray_dir := dir / ray_len

    // Add start polygon to path
    if max_path > 0 {
        path[0] = start_ref
        path_count = 1
    }

    cur_t := f32(0)

    for cur_t < ray_len {
        // Get current polygon
        tile, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, cur_ref)
        if recast.status_failed(poly_status) {
            break
        }

        // Find intersection with polygon edges
        next_ref := recast.INVALID_POLY_REF
        next_t := ray_len
        hit_edge := -1

        for i in 0..<int(poly.vert_count) {
            va := tile.verts[poly.verts[i]]
            vb := tile.verts[poly.verts[(i + 1) % int(poly.vert_count)]]

            // Test ray intersection with edge
            edge_t, intersects := geometry.ray_segment_intersect_2d(cur_pos, ray_dir, va, vb)

            if intersects && edge_t > cur_t && edge_t < next_t {
                // Check if there's a neighbor across this edge
                link := poly.first_link
                neighbor_found := false
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
                                next_ref = neighbor_ref
                                next_t = edge_t
                                neighbor_found = true
                                break
                            }
                        }
                    }
                    link = get_next_link(tile, link)
                }

                if !neighbor_found {
                    // Hit a wall
                    hit.t = edge_t
                    hit.hit_edge_index = i32(i)

                    // Calculate hit normal
                    edge_dir := vb - va
                    hit.hit_normal = {edge_dir.z, 0, -edge_dir.x} // Perpendicular in 2D
                    hit.hit_normal = linalg.normalize(hit.hit_normal)

                    return {.Success}, hit, path_count
                }
            }
        }

        if next_ref == recast.INVALID_POLY_REF {
            // No more intersections, ray ends in current polygon
            break
        }

        // Move to next polygon
        cur_ref = next_ref
        cur_t = next_t
        cur_pos = start_pos + ray_dir * cur_t

        // Add to path
        if path_count < max_path {
            path[path_count] = cur_ref
            path_count += 1
        }

        // Calculate cost if requested
        if (options & recast.DT_RAYCAST_USE_COSTS) != 0 {
            prev_cost := hit.path_cost
            segment_cost := query_filter_get_cost(filter,
                                                    start_pos + ray_dir * (cur_t - 0.01),
                                                    cur_pos,
                                                    recast.INVALID_POLY_REF, nil, nil,
                                                    cur_ref, tile, poly,
                                                    recast.INVALID_POLY_REF, nil, nil)
            hit.path_cost = prev_cost + segment_cost
        }
    }

    // Ray completed without hitting walls
    hit.t = ray_len
    return {.Success}, hit, path_count
}

// Find random point on navigation mesh
find_random_point :: proc(query: ^Nav_Mesh_Query, filter: ^Query_Filter) -> (ref: recast.Poly_Ref, pt: [3]f32, ret: recast.Status) {
    ref = recast.INVALID_POLY_REF
    // For simplicity, find first walkable polygon
    // A full implementation would properly sample based on polygon areas
    for i in 0..<query.nav_mesh.max_tiles {
        tile := &query.nav_mesh.tiles[i]
        if tile.header == nil {
            continue
        }

        for j in 0..<int(tile.header.poly_count) {
            poly := &tile.polys[j]
            ref := encode_poly_id(query.nav_mesh, tile.salt, u32(i), u32(j))
            if query_filter_pass_filter(filter, ref, tile, poly) {
                ref = ref
                pt = calc_poly_center(tile, poly)
                ret = {.Success}
                return
            }
        }
    }
    ret = {.Invalid_Param}
    return
}

// Find random point around given position
find_random_point_around_circle :: proc(query: ^Nav_Mesh_Query, start_ref: recast.Poly_Ref,
                                          start_pos: [3]f32, max_radius: f32, filter: ^Query_Filter) -> (ref: recast.Poly_Ref, pt: [3]f32, ret: recast.Status) {

    ref = recast.INVALID_POLY_REF
    pt = start_pos

    if !is_valid_poly_ref(query.nav_mesh, start_ref) {
        ret = {.Invalid_Param}
        return
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
    ret, ref, pt = find_nearest_poly(query, target, half_extents, filter)
    return
}

// Helper functions

query_polygons_in_tile :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile, qmin, qmax: [3]f32,
                                 polys: []recast.Poly_Ref, max_polys: i32) -> i32 {

    // For now, always use brute force to verify the BV tree issue
    // log.infof("    Using brute force for polygon query")

    // Fallback: test all polygons
    count := i32(0)
    base := get_poly_ref_base(nav_mesh, tile)

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
        // if i < 5 { // Debug first few polygons
        //     log.infof("    Polygon %d: bounds %v-%v, query %v-%v, overlap=%t",
        //               i, poly_min, poly_max, qmin, qmax, overlap)
        // }
        if geometry.overlap_bounds(qmin, qmax, poly_min, poly_max) {
            if count < max_polys {
                polys[count] = base | recast.Poly_Ref(i)
                count += 1
            }
        }
    }

    return count
}

query_polygons_in_tile_bv :: proc(nav_mesh: ^Nav_Mesh, tile: ^Mesh_Tile, qmin, qmax: [3]f32,
                                    polys: []recast.Poly_Ref, max_polys: i32) -> i32 {
    // BV tree traversal for spatial queries
    count := i32(0)
    base := get_poly_ref_base(nav_mesh, tile)

    // Convert query bounds to quantized space
    factor := tile.header.bv_quant_factor
    iqmin := geometry.quantize_float(qmin - tile.header.bmin, factor)
    iqmax := geometry.quantize_float(qmax - tile.header.bmin, factor)
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
    stack := make([]i32, 32)
    defer delete(stack)
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

        overlap := geometry.overlap_quantized_bounds(iqmin, iqmax, node_min, node_max)
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
                polys[count] = base | recast.Poly_Ref(node.i)
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

closest_point_on_polygon :: proc(tile: ^Mesh_Tile, poly: ^Poly, pos: [3]f32) -> ([3]f32, bool) {
    // Build polygon vertices
    verts := make([][3]f32, poly.vert_count)
    defer delete(verts)
    for i in 0..<int(poly.vert_count) {
        verts[i] = tile.verts[poly.verts[i]]
    }
    // Check if point is inside using 2D test
    inside := geometry.point_in_polygon_2d(pos, verts)
    if inside {
        // Point is inside polygon, use it directly but with polygon's Y height
        // Find the Y height at this XZ position (simplified: use average of vertices)
        avg_y := f32(0)
        for v in verts {
            avg_y += v.y
        }
        avg_y /= f32(len(verts))
        return {pos.x, avg_y, pos.z}, true
    }
    // Point is outside, find closest point on polygon edges
    closest := pos
    closest_dist_sqr := f32(math.F32_MAX)
    for i in 0..<int(poly.vert_count) {
        va := verts[i]
        vb := verts[(i + 1) % int(poly.vert_count)]
        edge_closest := geometry.closest_point_on_segment_2d(pos, va, vb)
        d := edge_closest - pos
        dist_sqr := linalg.length2(d.xz)
        if dist_sqr < closest_dist_sqr {
            closest_dist_sqr = dist_sqr
            closest = edge_closest
        }
    }
    return closest, false
}

// Get height of polygon at given position using detail mesh
get_poly_height :: proc(query: ^Nav_Mesh_Query, ref: recast.Poly_Ref, pos: [3]f32) -> (height: f32, status: recast.Status) {
    if !is_valid_poly_ref(query.nav_mesh, ref) {
        return 0, {.Invalid_Param}
    }
    tile, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if recast.status_failed(poly_status) {
        return 0, poly_status
    }
    // If no detail mesh, use polygon vertices for height calculation
    if tile.detail_meshes == nil || len(tile.detail_meshes) == 0 {
        // Calculate average height of polygon vertices
        avg_height := f32(0)
        for i in 0..<int(poly.vert_count) {
            avg_height += tile.verts[poly.verts[i]].y
        }
        return avg_height / f32(poly.vert_count), {.Success}
    }
    // Get detail mesh for this polygon
    poly_index := u32(ref) & u32(tile.header.poly_count - 1)
    if poly_index >= u32(len(tile.detail_meshes)) {
        return 0, {.Invalid_Param}
    }
    detail := &tile.detail_meshes[poly_index]
    // Find which detail triangle contains the position
    for i in 0..<int(detail.tri_count) {
        tri_idx := detail.tri_base + u32(i)
        if tri_idx >= u32(len(tile.detail_tris)) {
            continue
        }
        tri := &tile.detail_tris[tri_idx]
        // Get vertices of detail triangle
        verts: [3][3]f32
        for j in 0..<3 {
            if tri[j] < poly.vert_count {
                // Use polygon vertex
                verts[j] = tile.verts[poly.verts[tri[j]]]
            } else {
                // Use detail vertex
                detail_vert_idx := detail.vert_base + u32(tri[j] - poly.vert_count)
                if detail_vert_idx < u32(len(tile.detail_verts)) {
                    verts[j] = tile.detail_verts[detail_vert_idx]
                }
            }
        }
        // Check if point is inside triangle (2D test in XZ plane)
        if geometry.point_in_triangle_2d(pos, verts[0], verts[1], verts[2]) {
            // Calculate barycentric coordinates and interpolate height
            bary := geometry.barycentric_2d(pos, verts[0], verts[1], verts[2])
            height = verts[0].y * bary[0] + verts[1].y * bary[1] + verts[2].y * bary[2]
            return height, {.Success}
        }
    }
    // Fallback: use polygon center height
    center := calc_poly_center(tile, poly)
    return center.y, {.Success}
}

// Find distance from position to nearest wall
find_distance_to_wall :: proc(query: ^Nav_Mesh_Query, start_ref: recast.Poly_Ref, center_pos: [3]f32,
                               max_radius: f32, filter: ^Query_Filter) -> (hit_dist: f32, hit_pos: [3]f32, hit_normal: [3]f32, status: recast.Status) {

    if !is_valid_poly_ref(query.nav_mesh, start_ref) {
        return 0, {}, {}, {.Invalid_Param}
    }

    hit_dist = max_radius
    hit_normal = {0, 0, 0}

    // Use visited flags to avoid cycles
    visited := make(map[recast.Poly_Ref]bool)
    defer delete(visited)
    visited[start_ref] = true

    // Stack for traversal
    stack := make([]recast.Poly_Ref, 256)
    defer delete(stack)
    stack_size := 1
    stack[0] = start_ref

    for stack_size > 0 {
        stack_size -= 1
        cur_ref := stack[stack_size]

        tile, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, cur_ref)
        if recast.status_failed(poly_status) {
            continue
        }

        // Check all edges of current polygon
        for i in 0..<int(poly.vert_count) {
            va := tile.verts[poly.verts[i]]
            vb := tile.verts[poly.verts[(i+1) % int(poly.vert_count)]]

            // Check if this edge is a wall (no neighbor)
            is_wall := true
            poly_idx := get_poly_index(query.nav_mesh, cur_ref)
            link := get_first_link(tile, i32(poly_idx))

            for link != recast.DT_NULL_LINK {
                if get_link_edge(tile, link) == u8(i) {
                    neighbor_ref := get_link_poly_ref(tile, link)
                    if query_filter_pass_filter(filter, neighbor_ref, nil, nil) {
                        is_wall = false

                        // Add neighbor to stack if not visited
                        if _, exists := visited[neighbor_ref]; !exists && stack_size < 255 {
                            visited[neighbor_ref] = true
                            stack[stack_size] = neighbor_ref
                            stack_size += 1
                        }
                        break
                    }
                }
                link = get_next_link(tile, link)
            }

            if is_wall {
                // Calculate distance to edge
                closest := geometry.closest_point_on_segment_2d(center_pos, va, vb)
                dist := linalg.length(center_pos - closest)

                if dist < hit_dist {
                    hit_dist = dist
                    hit_pos = closest

                    // Calculate normal (perpendicular to edge)
                    edge := vb - va
                    hit_normal = {edge.z, 0, -edge.x}
                    hit_normal = linalg.normalize(hit_normal)
                }
            }
        }

        // Early exit if we've searched far enough
        center := calc_poly_center(tile, poly)
        if linalg.length(center - center_pos) > max_radius {
            break
        }
    }

    return hit_dist, hit_pos, hit_normal, {.Success}
}

// Find local neighborhood of polygons
find_local_neighbourhood :: proc(query: ^Nav_Mesh_Query, start_ref: recast.Poly_Ref, center_pos: [3]f32,
                                  radius: f32, filter: ^Query_Filter, result_ref: []recast.Poly_Ref,
                                  result_parent: []recast.Poly_Ref, max_result: i32) -> (result_count: i32, status: recast.Status) {

    if !is_valid_poly_ref(query.nav_mesh, start_ref) || max_result <= 0 {
        return 0, {.Invalid_Param}
    }

    result_count = 0

    // Use a simple flood fill within radius
    visited := make(map[recast.Poly_Ref]bool)
    defer delete(visited)

    // Queue for BFS
    queue := make([]struct{ref: recast.Poly_Ref, parent: recast.Poly_Ref}, 256)
    defer delete(queue)
    queue_head, queue_tail := 0, 1
    queue[0] = {start_ref, recast.INVALID_POLY_REF}

    visited[start_ref] = true

    for queue_head < queue_tail && result_count < max_result {
        cur := queue[queue_head]
        queue_head += 1

        tile, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, cur.ref)
        if recast.status_failed(poly_status) {
            continue
        }

        // Check if polygon center is within radius
        center := calc_poly_center(tile, poly)
        if linalg.length(center - center_pos) > radius {
            continue
        }

        // Add to results
        result_ref[result_count] = cur.ref
        result_parent[result_count] = cur.parent
        result_count += 1

        // Check all neighbors
        for i in 0..<int(poly.vert_count) {
            poly_idx := get_poly_index(query.nav_mesh, cur.ref)
            link := get_first_link(tile, i32(poly_idx))

            for link != recast.DT_NULL_LINK {
                if get_link_edge(tile, link) == u8(i) {
                    neighbor_ref := get_link_poly_ref(tile, link)

                    if _, exists := visited[neighbor_ref]; !exists {
                        neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                        if recast.status_succeeded(neighbor_status) &&
                           query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {

                            visited[neighbor_ref] = true

                            if queue_tail < 256 {
                                queue[queue_tail] = {neighbor_ref, cur.ref}
                                queue_tail += 1
                            }
                        }
                    }
                    break
                }
                link = get_next_link(tile, link)
            }
        }
    }

    return result_count, {.Success}
}

// Find polygons within circular area using Dijkstra search
find_polys_around_circle :: proc(query: ^Nav_Mesh_Query, start_ref: recast.Poly_Ref, center_pos: [3]f32,
                                   radius: f32, filter: ^Query_Filter, result_ref: []recast.Poly_Ref,
                                   result_parent: []recast.Poly_Ref, result_cost: []f32,
                                   max_result: i32) -> (result_count: i32, status: recast.Status) {

    if !is_valid_poly_ref(query.nav_mesh, start_ref) || max_result <= 0 {
        return 0, {.Invalid_Param}
    }

    // Check if result arrays have sufficient capacity
    if i32(len(result_ref)) < max_result || i32(len(result_parent)) < max_result || i32(len(result_cost)) < max_result {
        return 0, {.Invalid_Param}
    }

    result_count = 0
    radius_sqr := radius * radius

    // Clear node pool for search
    pathfinding_context_clear(&query.pf_context)
    node_queue_clear(&query.open_list)

    // Initialize start node
    start_node := create_node(&query.pf_context, start_ref)
    if start_node == nil {
        return 0, {.Out_Of_Nodes}
    }

    start_tile, start_poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, start_ref)
    if recast.status_failed(poly_status) {
        return 0, poly_status
    }

    start_node.pos, _ = closest_point_on_polygon(start_tile, start_poly, center_pos)
    start_node.cost = 0
    start_node.total = linalg.length2(start_node.pos - center_pos)
    start_node.flags = {.Open}
    start_node.parent_id = recast.INVALID_POLY_REF

    node_queue_push(&query.open_list, {start_ref, start_node.cost, start_node.total})

    // Dijkstra search with iteration limit to prevent hanging
    max_dijkstra_iterations := 100  // Much smaller limit for circle search
    dijkstra_iterations := 0

    for !node_queue_empty(&query.open_list) && dijkstra_iterations < max_dijkstra_iterations {
        dijkstra_iterations += 1

        if result_count >= max_result {
            break  // Found enough results
        }
        best := node_queue_pop(&query.open_list)
        if best.ref == recast.INVALID_POLY_REF {
            break
        }

        current := get_node(&query.pf_context, best.ref)
        if current == nil || .Closed in current.flags {
            continue
        }

        current.flags |= {.Closed}
        current.flags &= ~{.Open}

        // Check if within radius
        dist_sqr := linalg.length2(current.pos - center_pos)
        if dist_sqr <= radius_sqr {
            if result_count < max_result {
                result_ref[result_count] = current.id
                result_parent[result_count] = current.parent_id
                result_cost[result_count] = current.cost
                result_count += 1
            }
        }

        // Expand neighbors
        cur_tile, cur_poly, cur_status := get_tile_and_poly_by_ref(query.nav_mesh, current.id)
        if recast.status_failed(cur_status) {
            continue
        }

        poly_idx := get_poly_index(query.nav_mesh, current.id)
        link := get_first_link(cur_tile, i32(poly_idx))

        for link != recast.DT_NULL_LINK {
            neighbor_ref := get_link_poly_ref(cur_tile, link)
            if neighbor_ref != recast.INVALID_POLY_REF {
                neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                if recast.status_succeeded(neighbor_status) &&
                   query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {

                    neighbor_node := get_node(&query.pf_context, neighbor_ref)
                    if neighbor_node == nil {
                        neighbor_node = create_node(&query.pf_context, neighbor_ref)
                        if neighbor_node == nil {
                            break
                        }
                        neighbor_node.pos = calc_poly_center(neighbor_tile, neighbor_poly)
                    }

                    if .Closed in neighbor_node.flags {
                        link = get_next_link(cur_tile, link)
                        continue
                    }

                    step_cost := linalg.length(current.pos - neighbor_node.pos)
                    new_cost := current.cost + step_cost
                    new_dist_sqr := linalg.length2(neighbor_node.pos - center_pos)
                    new_total := new_cost + math.sqrt(new_dist_sqr)

                    if .Open in neighbor_node.flags && new_cost >= neighbor_node.cost {
                        link = get_next_link(cur_tile, link)
                        continue
                    }

                    neighbor_node.cost = new_cost
                    neighbor_node.total = new_total
                    neighbor_node.parent_id = current.id
                    neighbor_node.flags |= {.Open}

                    node_queue_push(&query.open_list, {neighbor_ref, neighbor_node.cost, neighbor_node.total})
                }
            }
            link = get_next_link(cur_tile, link)
        }
    }

    return result_count, {.Success}
}

// Find polygons within convex shape using Dijkstra search
find_polys_around_shape :: proc(query: ^Nav_Mesh_Query, start_ref: recast.Poly_Ref, verts: [][3]f32,
                                  filter: ^Query_Filter, result_ref: []recast.Poly_Ref,
                                  result_parent: []recast.Poly_Ref, result_cost: []f32,
                                  max_result: i32) -> (result_count: i32, status: recast.Status) {

    if !is_valid_poly_ref(query.nav_mesh, start_ref) || len(verts) < 3 || max_result <= 0 {
        return 0, {.Invalid_Param}
    }

    result_count = 0

    // Calculate shape center
    center := [3]f32{}
    for vert in verts {
        center += vert
    }
    center /= f32(len(verts))

    // Clear node pool for search
    pathfinding_context_clear(&query.pf_context)
    node_queue_clear(&query.open_list)

    // Initialize start node
    start_node := create_node(&query.pf_context, start_ref)
    if start_node == nil {
        return 0, {.Out_Of_Nodes}
    }

    start_tile, start_poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, start_ref)
    if recast.status_failed(poly_status) {
        return 0, poly_status
    }

    start_node.pos, _ = closest_point_on_polygon(start_tile, start_poly, center)
    start_node.cost = 0
    start_node.total = linalg.length(start_node.pos - center)
    start_node.flags = {.Open}
    start_node.parent_id = recast.INVALID_POLY_REF

    node_queue_push(&query.open_list, {start_ref, start_node.cost, start_node.total})

    // Dijkstra search
    for !node_queue_empty(&query.open_list) {
        best := node_queue_pop(&query.open_list)
        if best.ref == recast.INVALID_POLY_REF {
            break
        }

        current := get_node(&query.pf_context, best.ref)
        if current == nil || .Closed in current.flags {
            continue
        }

        current.flags |= {.Closed}
        current.flags &= ~{.Open}

        // Check if within shape
        if geometry.point_in_polygon_2d(current.pos, verts) {
            if result_count < max_result {
                result_ref[result_count] = current.id
                result_parent[result_count] = current.parent_id
                result_cost[result_count] = current.cost
                result_count += 1
            }
        }

        // Expand neighbors
        cur_tile, cur_poly, cur_status := get_tile_and_poly_by_ref(query.nav_mesh, current.id)
        if recast.status_failed(cur_status) {
            continue
        }

        poly_idx := get_poly_index(query.nav_mesh, current.id)
        link := get_first_link(cur_tile, i32(poly_idx))

        for link != recast.DT_NULL_LINK {
            neighbor_ref := get_link_poly_ref(cur_tile, link)
            if neighbor_ref != recast.INVALID_POLY_REF {
                neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, neighbor_ref)
                if recast.status_succeeded(neighbor_status) &&
                   query_filter_pass_filter(filter, neighbor_ref, neighbor_tile, neighbor_poly) {

                    neighbor_node := get_node(&query.pf_context, neighbor_ref)
                    if neighbor_node == nil {
                        neighbor_node = create_node(&query.pf_context, neighbor_ref)
                        if neighbor_node == nil {
                            break
                        }
                        neighbor_node.pos = calc_poly_center(neighbor_tile, neighbor_poly)
                    }

                    if .Closed in neighbor_node.flags {
                        link = get_next_link(cur_tile, link)
                        continue
                    }

                    step_cost := linalg.length(current.pos - neighbor_node.pos)
                    new_cost := current.cost + step_cost
                    new_total := new_cost + linalg.length(neighbor_node.pos - center)

                    if .Open in neighbor_node.flags && new_cost >= neighbor_node.cost {
                        link = get_next_link(cur_tile, link)
                        continue
                    }

                    neighbor_node.cost = new_cost
                    neighbor_node.total = new_total
                    neighbor_node.parent_id = current.id
                    neighbor_node.flags |= {.Open}

                    node_queue_push(&query.open_list, {neighbor_ref, neighbor_node.cost, neighbor_node.total})
                }
            }
            link = get_next_link(cur_tile, link)
        }
    }

    return result_count, {.Success}
}

// Get path from Dijkstra search results
get_path_from_dijkstra_search :: proc(query: ^Nav_Mesh_Query, end_ref: recast.Poly_Ref,
                                        path: []recast.Poly_Ref, max_path: i32) -> (path_count: i32, status: recast.Status) {

    if !is_valid_poly_ref(query.nav_mesh, end_ref) || max_path <= 0 {
        return 0, {.Invalid_Param}
    }

    end_node := get_node(&query.pf_context, end_ref)
    if end_node == nil || .Closed not_in end_node.flags {
        return 0, {.Invalid_Param}
    }

    result_status, result_path_count := get_path_to_node(query, end_node, path, max_path)
    return result_path_count, result_status
}

// Get wall segments for polygon
get_poly_wall_segments :: proc(query: ^Nav_Mesh_Query, ref: recast.Poly_Ref, filter: ^Query_Filter,
                                segment_verts: [][6]f32, segment_refs: []recast.Poly_Ref,
                                max_segments: i32) -> (segment_count: i32, status: recast.Status) {

    if !is_valid_poly_ref(query.nav_mesh, ref) || max_segments <= 0 {
        return 0, {.Invalid_Param}
    }

    segment_count = 0

    tile, poly, poly_status := get_tile_and_poly_by_ref(query.nav_mesh, ref)
    if recast.status_failed(poly_status) {
        return 0, poly_status
    }

    poly_idx := get_poly_index(query.nav_mesh, ref)

    for i in 0..<int(poly.vert_count) {
        if segment_count >= max_segments {
            break
        }

        va := tile.verts[poly.verts[i]]
        vb := tile.verts[poly.verts[(i+1) % int(poly.vert_count)]]

        // Find neighbor across this edge
        neighbor_ref := recast.INVALID_POLY_REF
        link := poly.first_link
        link_iterations := 0
        max_link_iterations := 32  // Safety limit to prevent infinite loops

        for link != recast.DT_NULL_LINK && link_iterations < max_link_iterations {
            link_iterations += 1

            if get_link_edge(tile, link) == u8(i) {
                potential_neighbor := get_link_poly_ref(tile, link)
                if potential_neighbor != recast.INVALID_POLY_REF {
                    neighbor_tile, neighbor_poly, neighbor_status := get_tile_and_poly_by_ref(query.nav_mesh, potential_neighbor)
                    if recast.status_succeeded(neighbor_status) &&
                       query_filter_pass_filter(filter, potential_neighbor, neighbor_tile, neighbor_poly) {
                        neighbor_ref = potential_neighbor
                        break
                    }
                }
            }
            link = get_next_link(tile, link)
        }

        // Store segment
        segment_verts[segment_count] = {va.x, va.y, va.z, vb.x, vb.y, vb.z}
        segment_refs[segment_count] = neighbor_ref
        segment_count += 1
    }

    return segment_count, {.Success}
}

// Check if polygon is in closed list during pathfinding
is_in_closed_list :: proc(query: ^Nav_Mesh_Query, ref: recast.Poly_Ref) -> bool {
    if query == nil {
        return false
    }

    node := get_node(&query.pf_context, ref)
    if node == nil {
        return false
    }

    return .Closed in node.flags
}

// Find closest point on polygon boundary
closest_point_on_poly_boundary :: proc(tile: ^Mesh_Tile, poly: ^Poly, pos: [3]f32) -> ([3]f32, bool) {
    closest := pos
    closest_dist_sqr := f32(math.F32_MAX)

    // Check all edges
    for i in 0..<int(poly.vert_count) {
        va := tile.verts[poly.verts[i]]
        vb := tile.verts[poly.verts[(i+1) % int(poly.vert_count)]]

        // Find closest point on edge
        edge_pt := geometry.closest_point_on_segment_2d(pos, va, vb)
        dist_sqr := linalg.length2(pos - edge_pt)

        if dist_sqr < closest_dist_sqr {
            closest_dist_sqr = dist_sqr
            closest = edge_pt
        }
    }

    // Check if original point was inside
    verts := make([][3]f32, poly.vert_count)
    defer delete(verts)
    for i in 0..<int(poly.vert_count) {
        verts[i] = tile.verts[poly.verts[i]]
    }
    inside := geometry.point_in_polygon_2d(pos, verts)

    return closest, inside
}
