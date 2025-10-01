package navigation_recast

import "core:slice"

// Erode walkable area by radius
erode_walkable_area :: proc(radius: i32, chf: ^Compact_Heightfield) -> bool {
    w := chf.width
    h := chf.height
    dist := make([]u8, len(chf.spans))
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
                    if get_con(s, dir) == RC_NOT_CONNECTED {
                        break
                    }
                    nx := x + get_dir_offset_x(dir)
                    ny := y + get_dir_offset_y(dir)
                    ni := chf.cells[nx + ny * w].index + u32(get_con(s, dir))
                    if chf.areas[ni] == RC_NULL_AREA {
                        break
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
                    ax := x + get_dir_offset_x(0)
                    ay := y + get_dir_offset_y(0)
                    ai := chf.cells[ax + ay * w].index + u32(get_con(s, 0))
                    nd = min(dist[ai] + 2, 250)
                    if nd < dist[i] do dist[i] = nd

                    // Process diagonal (-1,-1)
                    as := &chf.spans[ai]
                    if get_con(as, 3) != RC_NOT_CONNECTED {
                        aax := ax + get_dir_offset_x(3)
                        aay := ay + get_dir_offset_y(3)
                        aai := chf.cells[aax + aay * w].index + u32(get_con(as, 3))
                        nd = min(dist[aai] + 3, 250)
                        if nd < dist[i] do dist[i] = nd
                    }
                }

                // Process direction 3: (0,-1)
                if get_con(s, 3) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(3)
                    ay := y + get_dir_offset_y(3)
                    ai := chf.cells[ax + ay * w].index + u32(get_con(s, 3))
                    nd = min(dist[ai] + 2, 250)
                    if nd < dist[i] do dist[i] = nd

                    // Process diagonal (1,-1)
                    as := &chf.spans[ai]
                    if get_con(as, 2) != RC_NOT_CONNECTED {
                        aax := ax + get_dir_offset_x(2)
                        aay := ay + get_dir_offset_y(2)
                        aai := chf.cells[aax + aay * w].index + u32(get_con(as, 2))
                        nd = min(dist[aai] + 3, 250)
                        if nd < dist[i] do dist[i] = nd
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
                    ax := x + get_dir_offset_x(2)
                    ay := y + get_dir_offset_y(2)
                    ai := chf.cells[ax + ay * w].index + u32(get_con(s, 2))
                    nd = min(dist[ai] + 2, 250)
                    if nd < dist[i] do dist[i] = nd

                    // Process diagonal (1,1)
                    as := &chf.spans[ai]
                    if get_con(as, 1) != RC_NOT_CONNECTED {
                        aax := ax + get_dir_offset_x(1)
                        aay := ay + get_dir_offset_y(1)
                        aai := chf.cells[aax + aay * w].index + u32(get_con(as, 1))
                        nd = min(dist[aai] + 3, 250)
                        if nd < dist[i] do dist[i] = nd
                    }
                }

                // Process direction 1: (0,1)
                if get_con(s, 1) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(1)
                    ay := y + get_dir_offset_y(1)
                    ai := chf.cells[ax + ay * w].index + u32(get_con(s, 1))
                    nd = min(dist[ai] + 2, 250)
                    if nd < dist[i] do dist[i] = nd

                    // Process diagonal (-1,1)
                    as := &chf.spans[ai]
                    if get_con(as, 0) != RC_NOT_CONNECTED {
                        aax := ax + get_dir_offset_x(0)
                        aay := ay + get_dir_offset_y(0)
                        aai := chf.cells[aax + aay * w].index + u32(get_con(as, 0))
                        nd = min(dist[aai] + 3, 250)
                        if nd < dist[i] do dist[i] = nd
                    }
                }
            }
        }
    }
    thr := u8(radius * 2)
    for i in 0..<len(chf.spans) {
        if dist[i] < thr {
            chf.areas[i] = RC_NULL_AREA
        }
    }
    return true
}

// Build distance field
build_distance_field :: proc(chf: ^Compact_Heightfield) -> bool {
    // Clean up existing distance field
    delete(chf.dist)
    chf.dist = nil

    // Handle empty compact heightfield
    if len(chf.spans) == 0 {
        chf.dist = make([]u16, 0)
        chf.max_distance = 0
        return true
    }

    src := make([]u16, len(chf.spans))
    dst := make([]u16, len(chf.spans))

    chf.max_distance = calculate_distance_field(chf, src)

    // Box blur
    result := box_blur(chf, 1, src, dst)
    if raw_data(result) == raw_data(dst) {
        chf.dist = dst
        delete(src)  // Delete the unused buffer
    } else {
        chf.dist = src
        delete(dst)  // Delete the unused buffer
    }

    return true
}
