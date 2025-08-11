package navigation_recast

import "core:log"
import "core:math"
import "core:fmt"
import geometry "../../geometry"
import "core:math/linalg"
import "base:runtime"

// Axis enumeration for polygon division
Axis :: enum {
    X = 0,
    Y = 1,
    Z = 2,
}

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

        // Update merged span bounds (matches C++ lines 143-150)
        new_span.smin = min(new_span.smin, current_span.smin)
        new_span.smax = max(new_span.smax, current_span.smax)

        // Merge area flags (matches C++ lines 153-157)
        // The C++ checks the difference between the MERGED newSpan->smax and currentSpan->smax
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
divide_poly :: proc(in_verts: [][3]f32, in_verts_count: i32,
                   out_verts1: [][3]f32, out_verts1_count: ^i32,
                   out_verts2: [][3]f32, out_verts2_count: ^i32,
                   axis_offset: f32, axis: Axis) {
    assert(in_verts_count <= 12)

    // How far positive or negative away from the separating axis is each vertex
    in_vert_axis_delta: [12]f32
    for in_vert in 0..<in_verts_count {
        in_vert_axis_delta[in_vert] = axis_offset - in_verts[in_vert][axis]
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
            vert_a := in_verts[in_vert_a]
            vert_b := in_verts[in_vert_b]
            interpolated := linalg.mix(vert_b, vert_a, s)
            out_verts1[poly1_vert] = interpolated

            // Copy to second polygon
            out_verts2[poly2_vert] = interpolated
            poly1_vert += 1
            poly2_vert += 1

            // Add the in_vert_a point to the right polygon
            if in_vert_axis_delta[in_vert_a] > 0 {
                out_verts1[poly1_vert] = in_verts[in_vert_a]
                poly1_vert += 1
            } else if in_vert_axis_delta[in_vert_a] < 0 {
                out_verts2[poly2_vert] = in_verts[in_vert_a]
                poly2_vert += 1
            }
        } else {
            // Add the in_vert_a point to the right polygon
            if in_vert_axis_delta[in_vert_a] >= 0 {
                out_verts1[poly1_vert] = in_verts[in_vert_a]
                poly1_vert += 1
                if in_vert_axis_delta[in_vert_a] != 0 {
                    continue
                }
            }
            out_verts2[poly2_vert] = in_verts[in_vert_a]
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
    if !geometry.overlap_bounds(tri_bb_min, tri_bb_max, hf_bb_min, hf_bb_max) {
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
            log.infof("  Heightfield: BB=(%.2f,%.2f,%.2f)-(%.2f,%.2f,%.2f), size=%dx%d",
                     hf_bb_min.x, hf_bb_min.y, hf_bb_min.z,
                     hf_bb_max.x, hf_bb_max.y, hf_bb_max.z, w, h)
            debug_count += 1
        }
    }

    // use -1 rather than 0 to cut the polygon properly at the start of the tile
    z0 = math.clamp(z0, -1, h - 1)
    z1 = math.clamp(z1, 0, h - 1)

    // Clip the triangle into all grid cells it touches
    buf: [7 * 4][3]f32
    in_buf := buf[0:7]
    in_row := buf[7:14]
    p1 := buf[14:21]
    p2 := buf[21:28]

    in_buf[0] = v0
    in_buf[1] = v1
    in_buf[2] = v2
    nv_row: i32
    nv_in := i32(3)

    for z := z0; z <= z1; z += 1 {
        // Clip polygon to row. Store the remaining polygon as well
        cell_z := hf_bb_min.z + f32(z) * cell_size
        divide_poly(in_buf[:nv_in], nv_in, in_row[:7], &nv_row, p1[:7], &nv_in, cell_z + cell_size, .Z)
        in_buf, p1 = p1, in_buf

        if nv_row < 3 {
            continue
        }
        if z < 0 {
            continue
        }

        // find X-axis bounds of the row
        min_x := in_row[0].x
        max_x := in_row[0].x
        for vert in 1..<nv_row {
            if min_x > in_row[vert].x {
                min_x = in_row[vert].x
            }
            if max_x < in_row[vert].x {
                max_x = in_row[vert].x
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
            divide_poly(in_row[:nv2], nv2, p1[:7], &nv, p2[:7], &nv2, cx + cell_size, .X)
            in_row, p2 = p2, in_row

            if nv < 3 {
                continue
            }
            if x < 0 {
                continue
            }

            // Calculate min and max of the span
            span_min := p1[0].y
            span_max := p1[0].y
            for vert in 1..<nv {
                span_min = min(span_min, p1[vert].y)
                span_max = max(span_max, p1[vert].y)
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

// Rasterize triangles
rasterize_triangles :: proc(verts: [][3]f32, indices: []i32, tri_area_ids: []u8,
                           hf: ^Heightfield, flag_merge_threshold: i32) -> bool {
    // Rasterize the triangles
    inverse_cell_size := 1.0 / hf.cs
    inverse_cell_height := 1.0 / hf.ch
    num_tris := len(indices) / 3

    for tri_index in 0..<num_tris {
        v0 := verts[indices[tri_index * 3 + 0]]
        v1 := verts[indices[tri_index * 3 + 1]]
        v2 := verts[indices[tri_index * 3 + 2]]

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
                                     verts: [][3]f32,
                                     tris: []i32,
                                     areas: []u8) {
    walkable_thr := math.cos(math.to_radians(walkable_slope_angle))
    norm: [3]f32
    num_tris := len(tris) / 3

    for i in 0..<num_tris {
        tri := tris[i*3:]
        v0 := verts[tri[0]]
        v1 := verts[tri[1]]
        v2 := verts[tri[2]]

        norm = geometry.calc_tri_normal(v0, v1, v2)
        // Check if the face is NOT walkable (steep slope)
        if norm.y <= walkable_thr {
            areas[i] = RC_NULL_AREA
        }
    }
}

// Mark triangles by their walkable slope
mark_walkable_triangles :: proc(walkable_slope_angle: f32,
                                  verts: [][3]f32,
                                  tris: []i32,
                                  areas: []u8) {
    walkable_thr := math.cos(math.to_radians(walkable_slope_angle))
    norm: [3]f32
    num_tris := len(tris) / 3

    for i in 0..<num_tris {
        tri := tris[i*3:]
        v0 := verts[tri[0]]
        v1 := verts[tri[1]]
        v2 := verts[tri[2]]

        norm = geometry.calc_tri_normal(v0, v1, v2)
        // Check if the face is walkable (only mark NULL areas)
        if norm.y > walkable_thr && areas[i] == RC_NULL_AREA {
            areas[i] = RC_WALKABLE_AREA
        }
    }
}
