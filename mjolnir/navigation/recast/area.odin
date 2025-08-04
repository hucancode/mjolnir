package navigation_recast

import "core:slice"
import "core:log"

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
                    if get_con(s, dir) != RC_NOT_CONNECTED {
                        nx := x + get_dir_offset_x(dir)
                        ny := y + get_dir_offset_y(dir)
                        nc_cell := &chf.cells[nx + ny * w]
                        ni := nc_cell.index + u32(get_con(s, dir))
                        if chf.areas[ni] != RC_NULL_AREA {
                            nc += 1
                        }
                    }
                }
                // If not all 4 neighbors are walkable, this is a boundary cell
                if nc != 4 {
                    dist[i] = 0
                }
            }
        }
    }
    nd: u8
    // Pass 2
    for y := h - 1; y >= 0; y -= 1 {
        for x := w - 1; x >= 0; x -= 1 {
            c := &chf.cells[x + y * w]
            for i in c.index..<c.index + u32(c.count) {
                s := &chf.spans[i]
                if get_con(s, 2) != RC_NOT_CONNECTED {
                    // (1,0)
                    ax := int(x) + int(get_dir_offset_x(2))
                    ay := int(y) + int(get_dir_offset_y(2))
                    ac := &chf.cells[ax + ay * int(w)]
                    ai := ac.index + u32(get_con(s, 2))
                    as := &chf.spans[ai]
                    nd = min(dist[ai] + 2, 250)
                    if nd < dist[i] {
                        dist[i] = nd
                    }
                    // (1,1)
                    if get_con(as, 1) != RC_NOT_CONNECTED {
                        aax := ax + int(get_dir_offset_x(1))
                        aay := ay + int(get_dir_offset_y(1))
                        aac := &chf.cells[aax + aay * int(w)]
                        aai := aac.index + u32(get_con(as, 1))
                        nd = min(dist[aai] + 3, 250)
                        if nd < dist[i] {
                            dist[i] = nd
                        }
                    }
                }
                if get_con(s, 1) != RC_NOT_CONNECTED {
                    // (0,1)
                    ax := int(x) + int(get_dir_offset_x(1))
                    ay := int(y) + int(get_dir_offset_y(1))
                    ac := &chf.cells[ax + ay * int(w)]
                    ai := ac.index + u32(get_con(s, 1))
                    as := &chf.spans[ai]
                    nd = min(dist[ai] + 2, 250)
                    if nd < dist[i] {
                        dist[i] = nd
                    }
                    // (-1,1)
                    if get_con(as, 0) != RC_NOT_CONNECTED {
                        aax := ax + int(get_dir_offset_x(0))
                        aay := ay + int(get_dir_offset_y(0))
                        aac := &chf.cells[aax + aay * int(w)]
                        aai := aac.index + u32(get_con(as, 0))
                        nd = min(dist[aai] + 3, 250)
                        if nd < dist[i] {
                            dist[i] = nd
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

// Build distance field
build_distance_field :: proc(chf: ^Compact_Heightfield) -> bool {
    // Clean up existing distance field
    if chf.dist != nil {
        delete(chf.dist)
        chf.dist = nil
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
