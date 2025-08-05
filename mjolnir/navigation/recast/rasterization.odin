package navigation_recast

import "core:log"
import "core:math"
import "core:fmt"
import "core:math/linalg"
import "base:runtime"

// Axis enumeration for polygon division
Axis :: enum {
    X = 0,
    Y = 1,
    Z = 2,
}


// Allocates a new span in the heightfield.
// Uses a memory pool and free list to minimize actual allocations.
allocate_span :: proc(hf: ^Heightfield) -> ^Span {
    return alloc_span(hf)
}

// Releases the memory used by the span back to the heightfield
free_span :: proc(hf: ^Heightfield, span: ^Span) {
    if span == nil {
        return
    }
    // Clear span data before adding to freelist
    span.smin = 0
    span.smax = 0
    span.area = 0
    // Add the span to the front of the free list
    span.next = hf.freelist
    hf.freelist = span
}

// Span cache for recently accessed columns
Span_Column_Cache :: struct {
    column_index: i32,
    first_span: ^Span,
    span_count: i32,
    last_access: u32,
}

// Add span cache to heightfield (would need to be added to Heightfield struct)
// For now, we'll optimize the algorithm itself

// Adds a span to the heightfield with optimized merging
add_span :: proc(hf: ^Heightfield,
                 x, z: i32, smin, smax: u16, area_id: u8,
                 flag_merge_threshold: i32) -> bool {
    // Input validation with early exit
    if x < 0 || x >= hf.width || z < 0 || z >= hf.height {
        when ODIN_DEBUG {
            log.warnf("add_span: Invalid coordinates (%d, %d) for heightfield size %dx%d", x, z, hf.width, hf.height)
        }
        return false
    }

    if smin > smax {
        when ODIN_DEBUG {
            log.warnf("add_span: Invalid span range [%d, %d] - min must be <= max", smin, smax)
        }
        return false
    }

    column_index := x + z * hf.width
    
    // Fast path: empty column
    if hf.spans[column_index] == nil {
        new_span := allocate_span(hf)
        if new_span == nil do return false
        
        new_span.smin = u32(smin)
        new_span.smax = u32(smax)
        new_span.area = u32(area_id)
        new_span.next = nil
        hf.spans[column_index] = new_span
        return true
    }

    // Optimized merge with single pass
    // Pre-allocate span to avoid allocation in critical path
    new_span := allocate_span(hf)
    if new_span == nil do return false
    
    new_span.smin = u32(smin)
    new_span.smax = u32(smax)
    new_span.area = u32(area_id)
    new_span.next = nil

    // Track merge state
    merge_start: ^Span = nil
    merge_end: ^Span = nil
    insert_after: ^Span = nil
    
    previous_span: ^Span = nil
    current_span := hf.spans[column_index]
    
    // Single pass to find merge range and insertion point
    for current_span != nil {
        if current_span.smin > new_span.smax {
            // Found insertion point
            break
        }
        
        if current_span.smax < new_span.smin {
            // No overlap yet, update insertion point
            insert_after = current_span
            previous_span = current_span
            current_span = current_span.next
            continue
        }
        
        // Found overlap - mark merge range
        if merge_start == nil {
            merge_start = current_span
            insert_after = previous_span
        }
        merge_end = current_span
        
        // Update merged span bounds
        new_span.smin = min(new_span.smin, current_span.smin)
        new_span.smax = max(new_span.smax, current_span.smax)
        
        // Merge area flags
        // Check difference between the updated new_span.smax and current_span.smax
        // This matches the C++ implementation: rcAbs((int)newSpan->smax - (int)currentSpan->smax)
        if abs(i32(new_span.smax) - i32(current_span.smax)) <= flag_merge_threshold {
            // If within threshold, take max area
            new_span.area = max(new_span.area, current_span.area)
        }
        
        // Don't update previous_span when merging
        current_span = current_span.next
    }
    
    // Apply merges if any
    if merge_start != nil {
        // Save the next pointer after merge_end before modifying the list
        next_after_merge := merge_end.next
        

        
        // Free merged spans - be careful not to free past merge_end
        current := merge_start
        for current != nil {
            next := current.next
            free_span(hf, current)
            if current == merge_end {
                break
            }
            current = next
        }
        
        // Insert new merged span
        new_span.next = next_after_merge
        if insert_after != nil {
            insert_after.next = new_span
        } else {
            hf.spans[column_index] = new_span
        }
    } else {
        // No merge - just insert new span
        if insert_after != nil {
            new_span.next = insert_after.next
            insert_after.next = new_span
        } else {
            new_span.next = hf.spans[column_index]
            hf.spans[column_index] = new_span
        }
    }

    // Validate in debug mode
    when ODIN_DEBUG {
        validate_span_list(hf.spans[column_index], x, z)
    }

    return true
}

// Validate span list integrity (debug helper)
validate_span_list :: proc(first_span: ^Span, x, z: i32) {
    if first_span == nil do return

    // Use Floyd's cycle detection algorithm
    slow := first_span
    fast := first_span
    count := 0
    
    for fast != nil && fast.next != nil {
        slow = slow.next
        fast = fast.next.next
        count += 1
        
        if slow == fast {
            log.errorf("validate_span_list: Cycle detected in span list at column (%d, %d) after %d steps", x, z, count)
            panic("Span list has a cycle!")
        }
        
        if count > 1000 {
            log.errorf("validate_span_list: Too many spans in column (%d, %d)", x, z)
            break
        }
    }

    // Also validate ordering
    span := first_span
    prev_smax: u32 = 0
    
    for span != nil {
        smin := span.smin
        smax := span.smax

        // Check basic span validity
        if smin > smax {
            log.errorf("validate_span_list: Invalid span [%d, %d] in column (%d, %d)", smin, smax, x, z)
        }

        // Check ordering
        if count > 1 && smin < prev_smax {
            log.errorf("validate_span_list: Spans out of order in column (%d, %d): prev_smax=%d, curr_smin=%d", x, z, prev_smax, smin)
        }

        prev_smax = smax
        span = span.next
    }
}


// Divides a convex polygon of max 12 vertices into two convex polygons
// across a separating axis.
divide_poly :: proc(in_verts: []f32, in_verts_count: i32,
                   out_verts1: []f32, out_verts1_count: ^i32,
                   out_verts2: []f32, out_verts2_count: ^i32,
                   axis_offset: f32, axis: Axis) {
    assert(in_verts_count <= 12)

    // How far positive or negative away from the separating axis is each vertex
    in_vert_axis_delta: [12]f32
    for in_vert in 0..<in_verts_count {
        in_vert_axis_delta[in_vert] = axis_offset - in_verts[int(in_vert) * 3 + int(axis)]
    }

    poly1_vert := i32(0)
    poly2_vert := i32(0)

    for in_vert_a, in_vert_b := i32(0), in_verts_count - 1;
        in_vert_a < in_verts_count;
        in_vert_b, in_vert_a = in_vert_a, in_vert_a + 1 {

        // If the two vertices are on the same side of the separating axis
        same_side := (in_vert_axis_delta[in_vert_a] >= 0) == (in_vert_axis_delta[in_vert_b] >= 0)

        if !same_side {
            s := in_vert_axis_delta[in_vert_b] / (in_vert_axis_delta[in_vert_b] - in_vert_axis_delta[in_vert_a])
            // Interpolate between vertices
            vert_a := [3]f32{in_verts[in_vert_a * 3 + 0], in_verts[in_vert_a * 3 + 1], in_verts[in_vert_a * 3 + 2]}
            vert_b := [3]f32{in_verts[in_vert_b * 3 + 0], in_verts[in_vert_b * 3 + 1], in_verts[in_vert_b * 3 + 2]}
            interpolated := linalg.mix(vert_b, vert_a, s)
            out_verts1[poly1_vert * 3 + 0] = interpolated.x
            out_verts1[poly1_vert * 3 + 1] = interpolated.y
            out_verts1[poly1_vert * 3 + 2] = interpolated.z

            // Copy to second polygon
            copy(out_verts2[poly2_vert * 3:poly2_vert * 3 + 3], out_verts1[poly1_vert * 3:poly1_vert * 3 + 3])
            poly1_vert += 1
            poly2_vert += 1

            // Add the in_vert_a point to the right polygon
            if in_vert_axis_delta[in_vert_a] > 0 {
                copy(out_verts1[poly1_vert * 3:poly1_vert * 3 + 3], in_verts[in_vert_a * 3:in_vert_a * 3 + 3])
                poly1_vert += 1
            } else if in_vert_axis_delta[in_vert_a] < 0 {
                copy(out_verts2[poly2_vert * 3:poly2_vert * 3 + 3], in_verts[in_vert_a * 3:in_vert_a * 3 + 3])
                poly2_vert += 1
            }
        } else {
            // Add the in_vert_a point to the right polygon
            if in_vert_axis_delta[in_vert_a] >= 0 {
                copy(out_verts1[poly1_vert * 3:poly1_vert * 3 + 3], in_verts[in_vert_a * 3:in_vert_a * 3 + 3])
                poly1_vert += 1
                if in_vert_axis_delta[in_vert_a] != 0 {
                    continue
                }
            }
            copy(out_verts2[poly2_vert * 3:poly2_vert * 3 + 3], in_verts[in_vert_a * 3:in_vert_a * 3 + 3])
            poly2_vert += 1
        }
    }

    out_verts1_count^ = poly1_vert
    out_verts2_count^ = poly2_vert
}

// Rasterize a single triangle to the heightfield.
// This code is extremely hot, so much care should be given to maintaining maximum perf here.

rasterize_tri :: proc(v0, v1, v2: [3]f32, area_id: u8,
                     hf: ^Heightfield,
                     hf_bb_min, hf_bb_max: [3]f32,
                     cell_size, inverse_cell_size, inverse_cell_height: f32,
                     flag_merge_threshold: i32) -> bool {
    // Calculate the bounding box of the triangle
    tri_bb_min := [3]f32{
        min(v0.x, v1.x, v2.x),
        min(v0.y, v1.y, v2.y),
        min(v0.z, v1.z, v2.z),
    }
    tri_bb_max := [3]f32{
        max(v0.x, v1.x, v2.x),
        max(v0.y, v1.y, v2.y),
        max(v0.z, v1.z, v2.z),
    }

    // If the triangle does not touch the bounding box of the heightfield, skip the triangle
    if !overlap_bounds(tri_bb_min, tri_bb_max, hf_bb_min, hf_bb_max) {
        return true
    }

    w := hf.width
    h := hf.height
    by := hf_bb_max.y - hf_bb_min.y

    // Calculate the footprint of the triangle on the grid's z-axis
    z0 := i32((tri_bb_min.z - hf_bb_min.z) * inverse_cell_size)
    z1 := i32((tri_bb_max.z - hf_bb_min.z) * inverse_cell_size)

    // Debug logging for first few triangles
    when ODIN_DEBUG {
        @(static) debug_count := 0
        if debug_count < 10 {
            log.infof("Triangle %d: BB=(%.2f,%.2f,%.2f)-(%.2f,%.2f,%.2f), Grid Z=%d-%d, area=%d", 
                     debug_count, tri_bb_min.x, tri_bb_min.y, tri_bb_min.z,
                     tri_bb_max.x, tri_bb_max.y, tri_bb_max.z, z0, z1, area_id)
            debug_count += 1
        }
    }

    // use -1 rather than 0 to cut the polygon properly at the start of the tile
    z0 = math.clamp(z0, -1, h - 1)
    z1 = math.clamp(z1, 0, h - 1)

    // Clip the triangle into all grid cells it touches
    buf: [7 * 3 * 4]f32
    in_buf := buf[0:7*3]
    in_row := buf[7*3:14*3]
    p1 := buf[14*3:21*3]
    p2 := buf[21*3:28*3]

    in_buf[0] = v0.x
    in_buf[1] = v0.y
    in_buf[2] = v0.z
    in_buf[3] = v1.x
    in_buf[4] = v1.y
    in_buf[5] = v1.z
    in_buf[6] = v2.x
    in_buf[7] = v2.y
    in_buf[8] = v2.z
    nv_row: i32
    nv_in := i32(3)

    for z := z0; z <= z1; z += 1 {
        // Clip polygon to row. Store the remaining polygon as well
        cell_z := hf_bb_min.z + f32(z) * cell_size
        divide_poly(in_buf, nv_in, in_row, &nv_row, p1, &nv_in, cell_z + cell_size, .Z)
        in_buf, p1 = p1, in_buf

        if nv_row < 3 {
            continue
        }
        if z < 0 {
            continue
        }

        // find X-axis bounds of the row
        min_x := in_row[0]
        max_x := in_row[0]
        for vert in 1..<nv_row {
            if min_x > in_row[vert * 3] {
                min_x = in_row[vert * 3]
            }
            if max_x < in_row[vert * 3] {
                max_x = in_row[vert * 3]
            }
        }
        x0 := i32((min_x - hf_bb_min.x) * inverse_cell_size)
        x1 := i32((max_x - hf_bb_min.x) * inverse_cell_size)
        
        // Debug logging for X coordinates
        when ODIN_DEBUG {
            @(static) x_debug_count := 0
            if x_debug_count < 10 && z >= 0 && z < h {
                log.infof("  Row Z=%d: X range %.2f-%.2f -> Grid X=%d-%d (w=%d)", 
                         z, min_x, max_x, x0, x1, w)
                x_debug_count += 1
            }
        }
        
        if x1 < 0 || x0 >= w {
            continue
        }
        x0 = math.clamp(x0, -1, w - 1)
        x1 = math.clamp(x1, 0, w - 1)

        nv: i32
        nv2 := nv_row

        for x := x0; x <= x1; x += 1 {
            // Clip polygon to column. store the remaining polygon as well
            cx := hf_bb_min.x + f32(x) * cell_size
            divide_poly(in_row, nv2, p1, &nv, p2, &nv2, cx + cell_size, .X)
            in_row, p2 = p2, in_row

            if nv < 3 {
                continue
            }
            if x < 0 {
                continue
            }

            // Calculate min and max of the span
            span_min := p1[1]
            span_max := p1[1]
            for vert in 1..<nv {
                span_min = min(span_min, p1[vert * 3 + 1])
                span_max = max(span_max, p1[vert * 3 + 1])
            }
            span_min -= hf_bb_min.y
            span_max -= hf_bb_min.y

            // Skip the span if it's completely outside the heightfield bounding box
            if span_max < 0.0 {
                continue
            }
            if span_min > by {
                continue
            }

            // Clamp the span to the heightfield bounding box
            if span_min < 0.0 {
                span_min = 0
            }
            if span_max > by {
                span_max = by
            }

            // Snap the span to the heightfield height grid
            span_min_cell_index := u16(math.clamp(i32(math.floor(span_min * inverse_cell_height)), 0, RC_SPAN_MAX_HEIGHT))
            span_max_cell_index := u16(math.clamp(i32(math.ceil(span_max * inverse_cell_height)), i32(span_min_cell_index) + 1, RC_SPAN_MAX_HEIGHT))

            // Debug logging for spans
            when ODIN_DEBUG {
                @(static) span_debug_count := 0
                if span_debug_count < 20 {
                    log.infof("    Adding span at (%d,%d): height %d-%d, area=%d", 
                             x, z, span_min_cell_index, span_max_cell_index, area_id)
                    span_debug_count += 1
                }
            }
            
            if !add_span(hf, x, z, span_min_cell_index, span_max_cell_index, area_id, flag_merge_threshold) {
                return false
            }
        }
    }

    return true
}

// Rasterize a single triangle (public API)
rasterize_triangle :: proc(v0, v1, v2: [3]f32,
                             area_id: u8, hf: ^Heightfield,
                             flag_merge_threshold: i32) -> bool {
    // Rasterize the single triangle
    inverse_cell_size := 1.0 / hf.cs
    inverse_cell_height := 1.0 / hf.ch
    if !rasterize_tri(v0, v1, v2, area_id, hf, hf.bmin, hf.bmax,
                      hf.cs, inverse_cell_size, inverse_cell_height, flag_merge_threshold) {
        log.error("rcRasterizeTriangle: Out of memory.")
        return false
    }

    return true
}

// Rasterize triangles with indexed vertices (32-bit indices)
rasterize_triangles :: proc(verts: []f32, nv: i32,
                              tris: []i32, tri_area_ids: []u8, num_tris: i32,
                              hf: ^Heightfield, flag_merge_threshold: i32) -> bool {
    // Rasterize the triangles
    inverse_cell_size := 1.0 / hf.cs
    inverse_cell_height := 1.0 / hf.ch

    for tri_index in 0..<num_tris {
        v0 := [3]f32{
            verts[tris[tri_index * 3 + 0] * 3 + 0],
            verts[tris[tri_index * 3 + 0] * 3 + 1],
            verts[tris[tri_index * 3 + 0] * 3 + 2],
        }
        v1 := [3]f32{
            verts[tris[tri_index * 3 + 1] * 3 + 0],
            verts[tris[tri_index * 3 + 1] * 3 + 1],
            verts[tris[tri_index * 3 + 1] * 3 + 2],
        }
        v2 := [3]f32{
            verts[tris[tri_index * 3 + 2] * 3 + 0],
            verts[tris[tri_index * 3 + 2] * 3 + 1],
            verts[tris[tri_index * 3 + 2] * 3 + 2],
        }

        if !rasterize_tri(v0, v1, v2, tri_area_ids[tri_index], hf, hf.bmin, hf.bmax,
                          hf.cs, inverse_cell_size, inverse_cell_height, flag_merge_threshold) {
            log.error("rcRasterizeTriangles: Out of memory.")
            return false
        }
    }

    return true
}

// Rasterize triangles with indexed vertices (16-bit indices)
rc_rasterize_triangles_u16 :: proc(verts: []f32, nv: i32,
                                  tris: []u16, tri_area_ids: []u8, num_tris: i32,
                                  hf: ^Heightfield, flag_merge_threshold: i32) -> bool {
    // Removed timer code for simplicity

    // Rasterize the triangles
    inverse_cell_size := 1.0 / hf.cs
    inverse_cell_height := 1.0 / hf.ch

    for tri_index in 0..<num_tris {
        v0 := [3]f32{
            verts[tris[tri_index * 3 + 0] * 3 + 0],
            verts[tris[tri_index * 3 + 0] * 3 + 1],
            verts[tris[tri_index * 3 + 0] * 3 + 2],
        }
        v1 := [3]f32{
            verts[tris[tri_index * 3 + 1] * 3 + 0],
            verts[tris[tri_index * 3 + 1] * 3 + 1],
            verts[tris[tri_index * 3 + 1] * 3 + 2],
        }
        v2 := [3]f32{
            verts[tris[tri_index * 3 + 2] * 3 + 0],
            verts[tris[tri_index * 3 + 2] * 3 + 1],
            verts[tris[tri_index * 3 + 2] * 3 + 2],
        }

        if !rasterize_tri(v0, v1, v2, tri_area_ids[tri_index], hf, hf.bmin, hf.bmax,
                          hf.cs, inverse_cell_size, inverse_cell_height, flag_merge_threshold) {
            log.error("rcRasterizeTriangles: Out of memory.")
            return false
        }
    }

    return true
}

// Rasterize triangles without indices (direct vertex data)
rasterize_triangles_direct :: proc(verts: []f32, tri_area_ids: []u8, num_tris: i32,
                                     hf: ^Heightfield, flag_merge_threshold: i32) -> bool {
    // Removed timer code for simplicity

    // Rasterize the triangles
    inverse_cell_size := 1.0 / hf.cs
    inverse_cell_height := 1.0 / hf.ch

    for tri_index in 0..<num_tris {
        v0 := [3]f32{
            verts[(tri_index * 3 + 0) * 3 + 0],
            verts[(tri_index * 3 + 0) * 3 + 1],
            verts[(tri_index * 3 + 0) * 3 + 2],
        }
        v1 := [3]f32{
            verts[(tri_index * 3 + 1) * 3 + 0],
            verts[(tri_index * 3 + 1) * 3 + 1],
            verts[(tri_index * 3 + 1) * 3 + 2],
        }
        v2 := [3]f32{
            verts[(tri_index * 3 + 2) * 3 + 0],
            verts[(tri_index * 3 + 2) * 3 + 1],
            verts[(tri_index * 3 + 2) * 3 + 2],
        }

        if !rasterize_tri(v0, v1, v2, tri_area_ids[tri_index], hf, hf.bmin, hf.bmax,
                          hf.cs, inverse_cell_size, inverse_cell_height, flag_merge_threshold) {
            log.error("rcRasterizeTriangles: Out of memory.")
            return false
        }
    }

    return true
}

// Clear unwalkable triangles (mark steep slopes as non-walkable)
clear_unwalkable_triangles :: proc(walkable_slope_angle: f32,
                                     verts: []f32, nv: i32,
                                     tris: []i32, num_tris: i32,
                                     areas: []u8) {
    walkable_thr := math.cos(walkable_slope_angle * math.PI / 180.0)
    norm: [3]f32

    for i in 0..<num_tris {
        tri := tris[i*3:]
        v0 := [3]f32{verts[tri[0]*3+0], verts[tri[0]*3+1], verts[tri[0]*3+2]}
        v1 := [3]f32{verts[tri[1]*3+0], verts[tri[1]*3+1], verts[tri[1]*3+2]}
        v2 := [3]f32{verts[tri[2]*3+0], verts[tri[2]*3+1], verts[tri[2]*3+2]}

        norm = calc_tri_normal(v0, v1, v2)
        // Check if the face is NOT walkable (steep slope)
        if norm.y <= walkable_thr {
            areas[i] = RC_NULL_AREA
        }
    }
}

// Mark triangles by their walkable slope
mark_walkable_triangles :: proc(walkable_slope_angle: f32,
                                  verts: []f32, nv: i32,
                                  tris: []i32, num_tris: i32,
                                  areas: []u8) {
    walkable_thr := math.cos(walkable_slope_angle * math.PI / 180.0)
    norm: [3]f32

    for i in 0..<num_tris {
        tri := tris[i*3:]
        v0 := [3]f32{verts[tri[0]*3+0], verts[tri[0]*3+1], verts[tri[0]*3+2]}
        v1 := [3]f32{verts[tri[1]*3+0], verts[tri[1]*3+1], verts[tri[1]*3+2]}
        v2 := [3]f32{verts[tri[2]*3+0], verts[tri[2]*3+1], verts[tri[2]*3+2]}

        norm = calc_tri_normal(v0, v1, v2)
        // Check if the face is walkable
        if norm.y > walkable_thr {
            areas[i] = RC_WALKABLE_AREA
        }
    }
}

// Calculate triangle normal
@(private)
calc_tri_normal :: proc(v0, v1, v2: [3]f32) -> (norm: [3]f32) {
    e0 := v1 - v0
    e1 := v2 - v0
    norm = linalg.cross(e0, e1)
    norm = linalg.normalize(norm)
    return
}

// Clear unwalkable triangles with 16-bit indices
rc_clear_unwalkable_triangles_u16 :: proc(walkable_slope_angle: f32,
                                          verts: []f32, nv: i32,
                                          tris: []u16, num_tris: i32,
                                          areas: []u8) {
    walkable_thr := math.cos(walkable_slope_angle * math.PI / 180.0)
    norm: [3]f32

    for i in 0..<num_tris {
        tri := tris[i*3:]
        v0 := [3]f32{verts[tri[0]*3+0], verts[tri[0]*3+1], verts[tri[0]*3+2]}
        v1 := [3]f32{verts[tri[1]*3+0], verts[tri[1]*3+1], verts[tri[1]*3+2]}
        v2 := [3]f32{verts[tri[2]*3+0], verts[tri[2]*3+1], verts[tri[2]*3+2]}

        norm = calc_tri_normal(v0, v1, v2)
        // Check if the face is NOT walkable (steep slope)
        if norm.y <= walkable_thr {
            areas[i] = RC_NULL_AREA
        }
    }
}

// Mark walkable triangles with 16-bit indices
rc_mark_walkable_triangles_u16 :: proc(walkable_slope_angle: f32,
                                       verts: []f32, nv: i32,
                                       tris: []u16, num_tris: i32,
                                       areas: []u8) {
    walkable_thr := math.cos(walkable_slope_angle * math.PI / 180.0)
    norm: [3]f32

    for i in 0..<num_tris {
        tri := tris[i*3:]
        v0 := [3]f32{verts[tri[0]*3+0], verts[tri[0]*3+1], verts[tri[0]*3+2]}
        v1 := [3]f32{verts[tri[1]*3+0], verts[tri[1]*3+1], verts[tri[1]*3+2]}
        v2 := [3]f32{verts[tri[2]*3+0], verts[tri[2]*3+1], verts[tri[2]*3+2]}

        norm = calc_tri_normal(v0, v1, v2)
        // Check if the face is walkable
        if norm.y > walkable_thr {
            areas[i] = RC_WALKABLE_AREA
        }
    }
}

// Rasterize a box into the heightfield
rasterize_box :: proc(bmin, bmax: [3]f32,
                        area_id: u8, hf: ^Heightfield,
                        flag_merge_threshold: i32) -> bool {
    // Removed timer code for simplicity

    w := hf.width
    h := hf.height
    hf_bmin := hf.bmin
    hf_bmax := hf.bmax
    cs := hf.cs
    ch := hf.ch
    ics := 1.0 / cs
    ich := 1.0 / ch

    // Clip the box to heightfield bounds
    box_min := [3]f32{
        max(bmin.x, hf_bmin.x),
        max(bmin.y, hf_bmin.y),
        max(bmin.z, hf_bmin.z),
    }
    box_max := [3]f32{
        min(bmax.x, hf_bmax.x),
        min(bmax.y, hf_bmax.y),
        min(bmax.z, hf_bmax.z),
    }

    // Early out if box doesn't overlap heightfield
    if box_min.x >= box_max.x || box_min.y >= box_max.y || box_min.z >= box_max.z {
        return true
    }

    // Calculate cell coordinates
    x0 := i32((box_min.x - hf_bmin.x) * ics)
    y0 := i32((box_min.y - hf_bmin.y) * ich)
    z0 := i32((box_min.z - hf_bmin.z) * ics)
    x1 := i32((box_max.x - hf_bmin.x) * ics)
    y1 := i32((box_max.y - hf_bmin.y) * ich)
    z1 := i32((box_max.z - hf_bmin.z) * ics)

    // Clamp to field bounds
    x0 = math.clamp(x0, 0, w - 1)
    x1 = math.clamp(x1, 0, w - 1)
    z0 = math.clamp(z0, 0, h - 1)
    z1 = math.clamp(z1, 0, h - 1)

    // Add spans for the box
    for z := z0; z <= z1; z += 1 {
        for x := x0; x <= x1; x += 1 {
            smin := u16(math.clamp(y0, 0, RC_SPAN_MAX_HEIGHT))
            smax := u16(math.clamp(y1, i32(smin)+1, RC_SPAN_MAX_HEIGHT))
            if !add_span(hf, x, z, smin, smax, area_id, flag_merge_threshold) {
                log.error("rcRasterizeBox: Out of memory.")
                return false
            }
        }
    }

    return true
}

// Rasterize a convex volume into the heightfield
rasterize_convex_volume :: proc(verts: []f32, nverts: i32,
                                  min_y, max_y: f32,
                                  area_id: u8, hf: ^Heightfield,
                                  flag_merge_threshold: i32) -> bool {
    // Removed timer code for simplicity

    w := hf.width
    h := hf.height
    hf_bmin := hf.bmin
    hf_bmax := hf.bmax
    cs := hf.cs
    ch := hf.ch
    ics := 1.0 / cs
    ich := 1.0 / ch

    // Calculate the bounding box of the polygon
    poly_min := [3]f32{verts[0], min_y, verts[2]}
    poly_max := [3]f32{verts[0], max_y, verts[2]}

    for i in 1..<nverts {
        poly_min.x = min(poly_min.x, verts[i*3+0])
        poly_min.z = min(poly_min.z, verts[i*3+2])
        poly_max.x = max(poly_max.x, verts[i*3+0])
        poly_max.z = max(poly_max.z, verts[i*3+2])
    }

    // Clip to heightfield bounds
    poly_min.x = max(poly_min.x, hf_bmin.x)
    poly_min.y = max(poly_min.y, hf_bmin.y)
    poly_min.z = max(poly_min.z, hf_bmin.z)
    poly_max.x = min(poly_max.x, hf_bmax.x)
    poly_max.y = min(poly_max.y, hf_bmax.y)
    poly_max.z = min(poly_max.z, hf_bmax.z)

    // Early out if no overlap
    if poly_min.x >= poly_max.x || poly_min.y >= poly_max.y || poly_min.z >= poly_max.z {
        return true
    }

    // Calculate cell coordinates
    x0 := i32((poly_min.x - hf_bmin.x) * ics)
    y0 := i32((poly_min.y - hf_bmin.y) * ich)
    z0 := i32((poly_min.z - hf_bmin.z) * ics)
    x1 := i32((poly_max.x - hf_bmin.x) * ics)
    y1 := i32((poly_max.y - hf_bmin.y) * ich)
    z1 := i32((poly_max.z - hf_bmin.z) * ics)

    // Clamp to field bounds
    x0 = math.clamp(x0, 0, w - 1)
    x1 = math.clamp(x1, 0, w - 1)
    z0 = math.clamp(z0, 0, h - 1)
    z1 = math.clamp(z1, 0, h - 1)

    // Prepare polygon as [3]f32 array for point-in-poly test
    poly_verts := make([][3]f32, nverts, context.temp_allocator)
    for i in 0..<nverts {
        poly_verts[i] = [3]f32{verts[i*3+0], 0, verts[i*3+2]}
    }

    // Rasterize cells
    for z := z0; z <= z1; z += 1 {
        for x := x0; x <= x1; x += 1 {
            // Test if cell center is inside the polygon
            cell_x := hf_bmin.x + (f32(x) + 0.5) * cs
            cell_z := hf_bmin.z + (f32(z) + 0.5) * cs
            pt := [3]f32{cell_x, 0, cell_z}

            if point_in_polygon_2d(pt, poly_verts) {
                smin := u16(math.clamp(y0, 0, RC_SPAN_MAX_HEIGHT))
                smax := u16(math.clamp(y1, i32(smin)+1, RC_SPAN_MAX_HEIGHT))
                if !add_span(hf, x, z, smin, smax, area_id, flag_merge_threshold) {
                    log.error("rcRasterizeConvexVolume: Out of memory.")
                    return false
                }
            }
        }
    }

    return true
}
