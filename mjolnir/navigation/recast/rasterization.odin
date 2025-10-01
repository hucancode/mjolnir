package navigation_recast

import "core:math"
import "../../geometry"
import "core:math/linalg"

// Axis enumeration for polygon division
Axis :: enum {
    X = 0,
    Y = 1,
    Z = 2,
}

add_span :: proc(hf: ^Heightfield, x, z: i32, smin, smax: u16, area_id: u8, flag_merge_threshold: i32) -> bool {
    if x < 0 || x >= hf.width || z < 0 || z >= hf.height || smin > smax do return false
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
    // Track merge state
    merge_start: ^Span
    merge_end: ^Span
    insert_after: ^Span
    previous_span: ^Span
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
        if abs(i32(new_span.smax) - i32(current_span.smax)) <= flag_merge_threshold {
            new_span.area = max(new_span.area, current_span.area)
        }
        current_span = current_span.next
    }
    if merge_start != nil {
        next_after_merge := merge_end.next
        current := merge_start
        for current != nil {
            next := current.next
            free_span(hf, current)
            if current == merge_end do break
            current = next
        }
        new_span.next = next_after_merge
        if insert_after != nil {
            insert_after.next = new_span
        } else {
            hf.spans[column_index] = new_span
        }
    } else {
        if insert_after != nil {
            new_span.next = insert_after.next
            insert_after.next = new_span
        } else {
            new_span.next = hf.spans[column_index]
            hf.spans[column_index] = new_span
        }
    }
    return true
}

divide_poly :: proc(in_verts, out_verts1, out_verts2: [][3]f32, axis_offset: f32, axis: Axis) -> (poly1_vert_count: i32, poly2_vert_count: i32) {
    assert(len(in_verts) <= 12)

    in_vert_axis_delta: [12]f32
    for vert, i in in_verts {
        in_vert_axis_delta[i] = axis_offset - vert[axis]
    }

    for in_vert_a, in_vert_b := 0, len(in_verts) - 1;
        in_vert_a < len(in_verts);
        in_vert_b, in_vert_a = in_vert_a, in_vert_a + 1 {

        // If the two vertices are on the same side of the separating axis
        same_side := (in_vert_axis_delta[in_vert_a] >= 0) == (in_vert_axis_delta[in_vert_b] >= 0)

        if !same_side {
            s := in_vert_axis_delta[in_vert_b] / (in_vert_axis_delta[in_vert_b] - in_vert_axis_delta[in_vert_a])
            vert_a := in_verts[in_vert_a]
            vert_b := in_verts[in_vert_b]
            interpolated := linalg.mix(vert_b, vert_a, s)
            out_verts1[poly1_vert_count] = interpolated
            out_verts2[poly2_vert_count] = interpolated
            poly1_vert_count += 1
            poly2_vert_count += 1
            if in_vert_axis_delta[in_vert_a] > 0 {
                out_verts1[poly1_vert_count] = in_verts[in_vert_a]
                poly1_vert_count += 1
            } else if in_vert_axis_delta[in_vert_a] < 0 {
                out_verts2[poly2_vert_count] = in_verts[in_vert_a]
                poly2_vert_count += 1
            }
        } else {
            if in_vert_axis_delta[in_vert_a] >= 0 {
                out_verts1[poly1_vert_count] = in_verts[in_vert_a]
                poly1_vert_count += 1
                if in_vert_axis_delta[in_vert_a] != 0 do continue
            }
            out_verts2[poly2_vert_count] = in_verts[in_vert_a]
            poly2_vert_count += 1
        }
    }
    return
}

rasterize_triangle_with_inverse_cs :: proc(v0, v1, v2: [3]f32, area_id: u8,
                     hf: ^Heightfield,
                     hf_bb_min, hf_bb_max: [3]f32,
                     cell_size, inverse_cell_size, inverse_cell_height: f32,
                     flag_merge_threshold: i32) -> bool {
    tri_bb_min := linalg.min(v0, v1, v2)
    tri_bb_max := linalg.max(v0, v1, v2)
    if !geometry.overlap_bounds(tri_bb_min, tri_bb_max, hf_bb_min, hf_bb_max) do return true

    w := hf.width
    h := hf.height
    by := hf_bb_max.y - hf_bb_min.y

    tri_rel_min := tri_bb_min - hf_bb_min
    tri_rel_max := tri_bb_max - hf_bb_min
    z0 := i32(tri_rel_min.z * inverse_cell_size)
    z1 := i32(tri_rel_max.z * inverse_cell_size)

    // use -1 rather than 0 to cut the polygon properly at the start of the tile
    z0 = clamp(z0, -1, h - 1)
    z1 = clamp(z1, 0, h - 1)

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
        nv_row, nv_in = divide_poly(in_buf[:nv_in], in_row[:], p1[:], cell_z + cell_size, .Z)
        in_buf, p1 = p1, in_buf
        if nv_row < 3 || z < 0 do continue
        min_x := in_row[0].x
        max_x := in_row[0].x
        for vert in in_row[1:nv_row] {
            min_x = min(min_x, vert.x)
            max_x = max(max_x, vert.x)
        }
        x0 := i32((min_x - hf_bb_min.x) * inverse_cell_size)
        x1 := i32((max_x - hf_bb_min.x) * inverse_cell_size)

        if x1 < 0 || x0 >= w do continue
        x0 = clamp(x0, -1, w - 1)
        x1 = clamp(x1, 0, w - 1)

        nv: i32
        nv2 := nv_row

        for x := x0; x <= x1; x += 1 {
            // Clip polygon to column. store the remaining polygon as well
            cx := hf_bb_min.x + f32(x) * cell_size
            nv, nv2 = divide_poly(in_row[:nv2], p1[:], p2[:], cx + cell_size, .X)
            in_row, p2 = p2, in_row

            if nv < 3 || x < 0 do continue
            span_min := p1[0].y
            span_max := p1[0].y
            for vert in p1[1:nv] {
                span_min = min(span_min, vert.y)
                span_max = max(span_max, vert.y)
            }
            span_min -= hf_bb_min.y
            span_max -= hf_bb_min.y
            if span_max < 0.0 || span_min > by do continue
            span_min, span_max = max(span_min, 0.0), min(span_max, by)
            // Snap the span to the heightfield height grid
            span_min_cell_index := u16(clamp(i32(math.floor(span_min * inverse_cell_height)), 0, RC_SPAN_MAX_HEIGHT))
            span_max_cell_index := u16(clamp(i32(math.ceil(span_max * inverse_cell_height)), i32(span_min_cell_index) + 1, RC_SPAN_MAX_HEIGHT))
            add_span(hf, x, z, span_min_cell_index, span_max_cell_index, area_id, flag_merge_threshold) or_return
        }
    }

    return true
}

// Rasterize a single triangle
rasterize_triangle :: proc(v0, v1, v2: [3]f32,
                             area_id: u8, hf: ^Heightfield,
                             flag_merge_threshold: i32) -> bool {
    // Rasterize the single triangle
    inverse_cell_size := 1.0 / hf.cs
    inverse_cell_height := 1.0 / hf.ch
    return rasterize_triangle_with_inverse_cs(v0, v1, v2, area_id, hf, hf.bmin, hf.bmax,
                hf.cs, inverse_cell_size, inverse_cell_height, flag_merge_threshold)
}

// Rasterize triangles
rasterize_triangles :: proc(verts: [][3]f32, indices: []i32, tri_area_ids: []u8, hf: ^Heightfield, flag_merge_threshold: i32) -> bool {
    inverse_cs := 1.0 / hf.cs
    inverse_ch := 1.0 / hf.ch

    for i := 0; i < len(indices); i += 3 {
        v0 := verts[indices[i]]
        v1 := verts[indices[i+1]]
        v2 := verts[indices[i+2]]
        area := tri_area_ids[i/3]
        rasterize_triangle_with_inverse_cs(v0, v1, v2, area, hf, hf.bmin, hf.bmax, hf.cs, inverse_cs, inverse_ch, flag_merge_threshold) or_return
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
