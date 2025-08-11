package navigation_recast

import "core:slice"
import "core:log"
import "core:math"
import geometry "../../geometry"

// Import commonly used constants
EPSILON :: geometry.EPSILON

// Erode walkable area by radius
erode_walkable_area :: proc(radius: i32, chf: ^Compact_Heightfield) -> bool {
    w := chf.width
    h := chf.height
    dist := make([]u8, chf.span_count)
    defer delete(dist)
    // Init distance
    slice.fill(dist, 0xff)
    // Mark boundary cells
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            for i in c.index..<c.index + u32(c.count) {
                if chf.areas[i] == RC_NULL_AREA {
                    dist[i] = 0
                    continue
                }
                s := &chf.spans[i]
                nc := 0
                for dir in 0..<4 {
                    neighbor_con := get_con(s, dir)
                    if neighbor_con == RC_NOT_CONNECTED {
                        break // Early exit on disconnected neighbor
                    }
                    
                    nx := x + get_dir_offset_x(dir)
                    ny := y + get_dir_offset_y(dir)
                    // In a valid compact heightfield, if connection exists, neighbor must exist
                    // But add bounds check for safety
                    if nx < 0 || ny < 0 || nx >= w || ny >= h {
                        break // Invalid neighbor position
                    }
                    nc_cell := &chf.cells[nx + ny * w]
                    ni := nc_cell.index + u32(neighbor_con)
                    if chf.areas[ni] == RC_NULL_AREA {
                        break // Early exit on null area neighbor
                    }
                    nc += 1
                }
                // If not all 4 neighbors are walkable, this is a boundary cell
                if nc != 4 {
                    dist[i] = 0
                }
            }
        }
    }
    
    nd: u8
    
    // Pass 1 - Forward pass
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            for i in c.index..<c.index + u32(c.count) {
                s := &chf.spans[i]
                
                // Process direction 0: (-1,0)
                if get_con(s, 0) != RC_NOT_CONNECTED {
                    ax := int(x) + int(get_dir_offset_x(0))
                    ay := int(y) + int(get_dir_offset_y(0))
                    if ax >= 0 && ay >= 0 && ax < int(w) && ay < int(h) {
                        ac := &chf.cells[ax + ay * int(w)]
                        ai := ac.index + u32(get_con(s, 0))
                        if ai < u32(chf.span_count) {
                            as := &chf.spans[ai]
                            nd = min(dist[ai] + 2, 250)
                            if nd < dist[i] do dist[i] = nd
                            
                            // Process diagonal (-1,-1)
                            if get_con(as, 3) != RC_NOT_CONNECTED {
                                aax := ax + int(get_dir_offset_x(3))
                                aay := ay + int(get_dir_offset_y(3))
                                if aax >= 0 && aay >= 0 && aax < int(w) && aay < int(h) {
                                    aac := &chf.cells[aax + aay * int(w)]
                                    aai := aac.index + u32(get_con(as, 3))
                                    if aai < u32(chf.span_count) {
                                        nd = min(dist[aai] + 3, 250)
                                        if nd < dist[i] do dist[i] = nd
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Process direction 3: (0,-1) - reuse variables
                if get_con(s, 3) != RC_NOT_CONNECTED {
                    ax := int(x) + int(get_dir_offset_x(3))
                    ay := int(y) + int(get_dir_offset_y(3))
                    if ax >= 0 && ay >= 0 && ax < int(w) && ay < int(h) {
                        ac := &chf.cells[ax + ay * int(w)]
                        ai := ac.index + u32(get_con(s, 3))
                        if ai < u32(chf.span_count) {
                            as := &chf.spans[ai]
                            nd = min(dist[ai] + 2, 250)
                            if nd < dist[i] do dist[i] = nd
                            
                            // Process diagonal (1,-1)
                            if get_con(as, 2) != RC_NOT_CONNECTED {
                                aax := ax + int(get_dir_offset_x(2))
                                aay := ay + int(get_dir_offset_y(2))
                                if aax >= 0 && aay >= 0 && aax < int(w) && aay < int(h) {
                                    aac := &chf.cells[aax + aay * int(w)]
                                    aai := aac.index + u32(get_con(as, 2))
                                    if aai < u32(chf.span_count) {
                                        nd = min(dist[aai] + 3, 250)
                                        if nd < dist[i] do dist[i] = nd
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    // Pass 2 - Backward pass
    for y := h - 1; y >= 0; y -= 1 {
        for x := w - 1; x >= 0; x -= 1 {
            c := &chf.cells[x + y * w]
            for i in c.index..<c.index + u32(c.count) {
                s := &chf.spans[i]
                
                // Process direction 2: (1,0)
                if get_con(s, 2) != RC_NOT_CONNECTED {
                    ax := int(x) + int(get_dir_offset_x(2))
                    ay := int(y) + int(get_dir_offset_y(2))
                    if ax >= 0 && ay >= 0 && ax < int(w) && ay < int(h) {
                        ac := &chf.cells[ax + ay * int(w)]
                        ai := ac.index + u32(get_con(s, 2))
                        if ai < u32(chf.span_count) {
                            as := &chf.spans[ai]
                            nd = min(dist[ai] + 2, 250)
                            if nd < dist[i] do dist[i] = nd
                            
                            // Process diagonal (1,1)
                            if get_con(as, 1) != RC_NOT_CONNECTED {
                                aax := ax + int(get_dir_offset_x(1))
                                aay := ay + int(get_dir_offset_y(1))
                                if aax >= 0 && aay >= 0 && aax < int(w) && aay < int(h) {
                                    aac := &chf.cells[aax + aay * int(w)]
                                    aai := aac.index + u32(get_con(as, 1))
                                    if aai < u32(chf.span_count) {
                                        nd = min(dist[aai] + 3, 250)
                                        if nd < dist[i] do dist[i] = nd
                                    }
                                }
                            }
                        }
                    }
                }
                
                // Process direction 1: (0,1) - reuse variables
                if get_con(s, 1) != RC_NOT_CONNECTED {
                    ax := int(x) + int(get_dir_offset_x(1))
                    ay := int(y) + int(get_dir_offset_y(1))
                    if ax >= 0 && ay >= 0 && ax < int(w) && ay < int(h) {
                        ac := &chf.cells[ax + ay * int(w)]
                        ai := ac.index + u32(get_con(s, 1))
                        if ai < u32(chf.span_count) {
                            as := &chf.spans[ai]
                            nd = min(dist[ai] + 2, 250)
                            if nd < dist[i] do dist[i] = nd
                            
                            // Process diagonal (-1,1)
                            if get_con(as, 0) != RC_NOT_CONNECTED {
                                aax := ax + int(get_dir_offset_x(0))
                                aay := ay + int(get_dir_offset_y(0))
                                if aax >= 0 && aay >= 0 && aax < int(w) && aay < int(h) {
                                    aac := &chf.cells[aax + aay * int(w)]
                                    aai := aac.index + u32(get_con(as, 0))
                                    if aai < u32(chf.span_count) {
                                        nd = min(dist[aai] + 3, 250)
                                        if nd < dist[i] do dist[i] = nd
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    thr := u8(radius * 2)
    for i in 0..<chf.span_count {
        if dist[i] < thr {
            chf.areas[i] = RC_NULL_AREA
        }
    }
    return true
}

// Safe normalize vector - normalizes only if magnitude is greater than epsilon
// If magnitude is zero, vector is unchanged
safe_normalize :: proc(v: ^[3]f32) {
    sq_mag := v.x * v.x + v.y * v.y + v.z * v.z
    if sq_mag <= EPSILON do return
    
    inv_mag := 1.0 / math.sqrt(sq_mag)
    v.x *= inv_mag
    v.y *= inv_mag
    v.z *= inv_mag
}

// Offset polygon - creates an inset/outset polygon with proper miter/bevel handling
// Returns the offset vertices and success status
offset_poly :: proc(verts: [][3]f32, offset: f32, allocator := context.allocator) -> (out_verts: [dynamic][3]f32, ok: bool) {
    // Defines the limit at which a miter becomes a bevel
    // Similar in behavior to https://developer.mozilla.org/en-US/docs/Web/SVG/Attribute/stroke-miterlimit
    MITER_LIMIT :: 1.20

    num_verts := len(verts)
    if num_verts < 3 do return nil, false

    // First pass: calculate how many vertices we'll need
    estimated_verts := num_verts * 2  // Conservative estimate for beveling
    out_verts = make([dynamic][3]f32, 0, estimated_verts)

    for vert_index in 0..<num_verts {
        // Grab three vertices of the polygon
        vert_index_a := (vert_index + num_verts - 1) % num_verts
        vert_index_b := vert_index
        vert_index_c := (vert_index + 1) % num_verts

        vert_a := verts[vert_index_a]
        vert_b := verts[vert_index_b]
        vert_c := verts[vert_index_c]

        // From A to B on the x/z plane
        prev_segment_dir: [3]f32
        prev_segment_dir.x = vert_b.x - vert_a.x
        prev_segment_dir.y = 0 // Squash onto x/z plane
        prev_segment_dir.z = vert_b.z - vert_a.z
        safe_normalize(&prev_segment_dir)

        // From B to C on the x/z plane
        curr_segment_dir: [3]f32
        curr_segment_dir.x = vert_c.x - vert_b.x
        curr_segment_dir.y = 0 // Squash onto x/z plane
        curr_segment_dir.z = vert_c.z - vert_b.z
        safe_normalize(&curr_segment_dir)

        // The y component of the cross product of the two normalized segment directions
        // The X and Z components of the cross product are both zero because the two
        // segment direction vectors fall within the x/z plane
        cross := curr_segment_dir.x * prev_segment_dir.z - prev_segment_dir.x * curr_segment_dir.z

        // CCW perpendicular vector to AB. The segment normal
        prev_segment_norm_x := -prev_segment_dir.z
        prev_segment_norm_z := prev_segment_dir.x

        // CCW perpendicular vector to BC. The segment normal
        curr_segment_norm_x := -curr_segment_dir.z
        curr_segment_norm_z := curr_segment_dir.x

        // Average the two segment normals to get the proportional miter offset for B
        // This isn't normalized because it's defining the distance and direction the corner will need to be
        // adjusted proportionally to the edge offsets to properly miter the adjoining edges
        corner_miter_x := (prev_segment_norm_x + curr_segment_norm_x) * 0.5
        corner_miter_z := (prev_segment_norm_z + curr_segment_norm_z) * 0.5
        corner_miter_sq_mag := corner_miter_x * corner_miter_x + corner_miter_z * corner_miter_z

        // If the magnitude of the segment normal average is less than about .69444,
        // the corner is an acute enough angle that the result should be beveled
        bevel := corner_miter_sq_mag * MITER_LIMIT * MITER_LIMIT < 1.0

        // Scale the corner miter so it's proportional to how much the corner should be offset compared to the edges
        if corner_miter_sq_mag > EPSILON {
            scale := 1.0 / corner_miter_sq_mag
            corner_miter_x *= scale
            corner_miter_z *= scale
        }

        if bevel && cross < 0.0 { // If the corner is convex and an acute enough angle, generate a bevel
            // Generate two bevel vertices at distances from B proportional to the angle between the two segments
            // Move each bevel vertex out proportional to the given offset
            d := (1.0 - (prev_segment_dir.x * curr_segment_dir.x + prev_segment_dir.z * curr_segment_dir.z)) * 0.5

            append(&out_verts, [3]f32{
                vert_b.x + (-prev_segment_norm_x + prev_segment_dir.x * d) * offset,
                vert_b.y,
                vert_b.z + (-prev_segment_norm_z + prev_segment_dir.z * d) * offset,
            })

            append(&out_verts, [3]f32{
                vert_b.x + (-curr_segment_norm_x - curr_segment_dir.x * d) * offset,
                vert_b.y,
                vert_b.z + (-curr_segment_norm_z - curr_segment_dir.z * d) * offset,
            })
        } else {
            // Move B along the miter direction by the specified offset
            append(&out_verts, [3]f32{
                vert_b.x - corner_miter_x * offset,
                vert_b.y,
                vert_b.z - corner_miter_z * offset,
            })
        }
    }

    // Allocate final output with the exact size needed
    if len(out_verts) == 0 {
        delete(out_verts)
        return nil, false
    }

    return out_verts, true
}

// Build distance field
build_distance_field :: proc(chf: ^Compact_Heightfield) -> bool {
    // Clean up existing distance field
    if chf.dist != nil {
        delete(chf.dist)
        chf.dist = nil
    }
    
    // Handle empty compact heightfield
    if chf.span_count == 0 {
        chf.dist = make([]u16, 0)
        chf.max_distance = 0
        return true
    }
    
    src := make([]u16, chf.span_count)
    if src == nil {
        log.errorf("build_distance_field: Out of memory 'src' (%d)", chf.span_count)
        return false
    }
    defer delete(src)

    dst := make([]u16, chf.span_count)
    if dst == nil {
        log.errorf("build_distance_field: Out of memory 'dst' (%d)", chf.span_count)
        return false
    }

    w := chf.width
    h := chf.height
    chf.max_distance = calculate_distance_field(chf, src)
    // Box blur
    {
        result := box_blur(chf, 1, src, dst)
        if raw_data(result) == raw_data(dst) {
            chf.dist = dst
        } else {
            chf.dist = src
        }
    }

    return true
}
