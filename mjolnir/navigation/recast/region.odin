package navigation_recast

import "core:slice"
import "core:mem"
import "core:math"
import "core:log"

// Region building constants
RC_NULL_NEI :: 0xffff

// Stack entry for level-based flood fill
Level_Stack_Entry :: struct {
    x:     i32,
    y:     i32,
    index: i32,
}

// Sweep span for monotone partitioning
Sweep_Span :: struct {
    rid:  u16,    // row id
    id:   u16,    // region id
    ns:   u16,    // number samples
    nei:  u16,    // neighbour id
}

// Dirty entry for tracking modified regions during expansion
Dirty_Entry :: struct {
    index:     i32,
    region:    u16,
    distance2: u16,
}

// Region structure for merge and filter operations
Region :: struct {
    span_count:        i32,
    id:                u16,
    area_type:         u8,
    remap:             bool,
    visited:           bool,
    overlap:           bool,
    connects_to_border: bool,
    ymin:              u16,
    ymax:              u16,
    connections:       [dynamic]i32,
    floors:            [dynamic]i32,
}

// Use get_con from filter.odin which is already imported

// Calculate distance field for watershed algorithm
@(optimization_mode="none")
calculate_distance_field :: proc(chf: ^Compact_Heightfield, src: []u16) -> (max_dist: u16) {
    w := chf.width
    h := chf.height

    // Init distance
    slice.fill(src[:chf.span_count], 0xffff)

    // Safety check for extremely large grids
    if int(w) * int(h) > 1000000 {
        log.errorf("Distance field calculation: grid size %dx%d too large", w, h)
        return 0
    }

    // Mark boundary cells (spans that are not fully connected)
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            span_start := u32(c.index)
            span_count := c.count

            if span_count == 0 {
                continue
            }

            if span_start >= u32(len(chf.spans)) {
                continue
            }

            for i in span_start..<span_start + u32(span_count) {
                if i >= u32(len(chf.areas)) || i >= u32(len(chf.spans)) || i >= u32(len(src)) {
                    continue
                }

                area := chf.areas[i]
                s := &chf.spans[i]

                nc := 0
                for dir in 0..<4 {
                    if get_con(s, dir) != RC_NOT_CONNECTED {
                        ax := x + get_dir_offset_x(dir)
                        ay := y + get_dir_offset_y(dir)
                        if ax >= 0 && ay >= 0 && ax < w && ay < h {
                            ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, dir))
                            if ai < u32(len(chf.areas)) && area == chf.areas[ai] {
                                nc += 1
                            }
                        }
                    }
                }
                if nc != 4 {
                    src[i] = 0
                }
            }
        }
    }

    // Pass 1 - propagate distances (forward pass)
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            span_start := u32(c.index)
            span_count := c.count

            for i in span_start..<span_start + u32(span_count) {
                if i >= u32(len(chf.spans)) || i >= u32(len(src)) {
                    continue
                }
                s := &chf.spans[i]

                if get_con(s, 0) != RC_NOT_CONNECTED {
                    // Process direction 0 (-1,0)
                    ax := x + get_dir_offset_x(0)
                    ay := y + get_dir_offset_y(0)
                    if ax >= 0 && ay >= 0 && ax < w && ay < h {
                        ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, 0))
                        if ai < u32(len(src)) && src[ai] + 2 < src[i] {
                            src[i] = src[ai] + 2
                        }

                        // Diagonal (-1,-1)
                        if ai < u32(len(chf.spans)) {
                            as := &chf.spans[ai]
                            if get_con(as, 3) != RC_NOT_CONNECTED {
                                aax := ax + get_dir_offset_x(3)
                                aay := ay + get_dir_offset_y(3)
                                if aax >= 0 && aay >= 0 && aax < w && aay < h {
                                    aai := u32(chf.cells[aax + aay * w].index) + u32(get_con(as, 3))
                                    if aai < u32(len(src)) && src[aai] + 3 < src[i] {
                                        src[i] = src[aai] + 3
                                    }
                                }
                            }
                        }
                    }
                }

                // Process direction 3 (0,-1)
                if get_con(s, 3) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(3)
                    ay := y + get_dir_offset_y(3)
                    if ax >= 0 && ay >= 0 && ax < w && ay < h {
                        ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, 3))
                        if ai < u32(len(src)) && src[ai] + 2 < src[i] {
                            src[i] = src[ai] + 2
                        }

                        // Diagonal (1,-1)
                        if ai < u32(len(chf.spans)) {
                            as := &chf.spans[ai]
                            if get_con(as, 2) != RC_NOT_CONNECTED {
                                aax := ax + get_dir_offset_x(2)
                                aay := ay + get_dir_offset_y(2)
                                if aax >= 0 && aay >= 0 && aax < w && aay < h {
                                    aai := u32(chf.cells[aax + aay * w].index) + u32(get_con(as, 2))
                                    if aai < u32(len(src)) && src[aai] + 3 < src[i] {
                                        src[i] = src[aai] + 3
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Pass 2 - propagate in reverse direction (backward pass)
    for y := h - 1; y >= 0; y -= 1 {
        for x := w - 1; x >= 0; x -= 1 {
            c := &chf.cells[x + y * w]
            span_start := u32(c.index)
            span_count := c.count

            for i in span_start..<span_start + u32(span_count) {
                if i >= u32(len(chf.spans)) || i >= u32(len(src)) {
                    continue
                }
                s := &chf.spans[i]

                // Process direction 2 (1,0)
                if get_con(s, 2) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(2)
                    ay := y + get_dir_offset_y(2)
                    if ax >= 0 && ay >= 0 && ax < w && ay < h {
                        ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, 2))
                        if ai < u32(len(src)) && src[ai] + 2 < src[i] {
                            src[i] = src[ai] + 2
                        }

                        // Diagonal (1,1)
                        if ai < u32(len(chf.spans)) {
                            as := &chf.spans[ai]
                            if get_con(as, 1) != RC_NOT_CONNECTED {
                                aax := ax + get_dir_offset_x(1)
                                aay := ay + get_dir_offset_y(1)
                                if aax >= 0 && aay >= 0 && aax < w && aay < h {
                                    aai := u32(chf.cells[aax + aay * w].index) + u32(get_con(as, 1))
                                    if aai < u32(len(src)) && src[aai] + 3 < src[i] {
                                        src[i] = src[aai] + 3
                                    }
                                }
                            }
                        }
                    }
                }

                // Process direction 1 (0,1)
                if get_con(s, 1) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(1)
                    ay := y + get_dir_offset_y(1)
                    if ax >= 0 && ay >= 0 && ax < w && ay < h {
                        ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, 1))
                        if ai < u32(len(src)) && src[ai] + 2 < src[i] {
                            src[i] = src[ai] + 2
                        }

                        // Diagonal (-1,1)
                        if ai < u32(len(chf.spans)) {
                            as := &chf.spans[ai]
                            if get_con(as, 0) != RC_NOT_CONNECTED {
                                aax := ax + get_dir_offset_x(0)
                                aay := ay + get_dir_offset_y(0)
                                if aax >= 0 && aay >= 0 && aax < w && aay < h {
                                    aai := u32(chf.cells[aax + aay * w].index) + u32(get_con(as, 0))
                                    if aai < u32(len(src)) && src[aai] + 3 < src[i] {
                                        src[i] = src[aai] + 3
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    return slice.max(src[0:chf.span_count])
}

// Box blur for distance field smoothing
@(optimization_mode="none")
box_blur :: proc(chf: ^Compact_Heightfield, thr: i32, src, dst: []u16) -> []u16 {
    w := chf.width
    h := chf.height
    threshold := thr * 2

    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                s := &chf.spans[i]
                cd := src[i]
                if cd <= u16(threshold) {
                    dst[i] = cd
                    continue
                }
                d := i32(cd)
                for dir in 0..<4 {
                    if get_con(s, dir) == RC_NOT_CONNECTED {
                        d += i32(cd) * 2
                        continue
                    }
                    ax := x + get_dir_offset_x(dir)
                    ay := y + get_dir_offset_y(dir)
                    ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, dir))
                    d += i32(src[ai])
                    as := &chf.spans[ai]
                    dir2 := (dir + 1) & 0x3
                    if get_con(as, dir2) == RC_NOT_CONNECTED {
                        d += i32(cd)
                        continue
                    }
                    ax2 := ax + get_dir_offset_x(dir2)
                    ay2 := ay + get_dir_offset_y(dir2)
                    ai2 := chf.cells[ax2 + ay2 * w].index + u32(get_con(as, dir2))
                    d += i32(src[ai2])
                }
                dst[i] = u16((d + 5) / 9)
            }
        }
    }
    return dst
}

// Flood region - level set based region growing
@(optimization_mode="none")
flood_region :: proc(x, y, i: i32, level, r: u16, chf: ^Compact_Heightfield,
                    src_reg, src_dist: []u16, stack: ^[dynamic]Level_Stack_Entry) -> bool {
    w := chf.width
    h := chf.height
    area := chf.areas[i]

    // Flood fill mark region
    clear(stack)
    append(stack, Level_Stack_Entry{x, y, i})
    src_reg[i] = r
    src_dist[i] = 0

    lev := level >= 2 ? level - 2 : 0
    count := 0

    for len(stack) > 0 {
        back := pop(stack)
        cx := back.x
        cy := back.y
        ci := back.index

        cs := &chf.spans[ci]

        // Check if any of the neighbours already have a valid region set
        ar: u16 = 0
        for dir in 0..<4 {
            // 8 connected
            if get_con(cs, dir) == RC_NOT_CONNECTED {
                continue
            }
            ax := cx + get_dir_offset_x(dir)
            ay := cy + get_dir_offset_y(dir)
            if ax < 0 || ay < 0 || ax >= w || ay >= h {
                continue
            }
            ai := i32(u32(chf.cells[ax + ay * w].index)) + i32(get_con(cs, dir))
            if chf.areas[ai] != area {
                continue
            }
            nr := src_reg[ai]
            if (nr & RC_BORDER_REG) != 0 { // Do not take borders into account
                continue
            }
            if nr != 0 && nr != r {
                ar = nr
                break
            }

            as := &chf.spans[ai]

            dir2 := (dir + 1) & 0x3
            if get_con(as, dir2) == RC_NOT_CONNECTED {
                continue
            }
            ax2 := ax + get_dir_offset_x(dir2)
            ay2 := ay + get_dir_offset_y(dir2)
            if ax2 < 0 || ay2 < 0 || ax2 >= w || ay2 >= h {
                continue
            }
            ai2 := i32(chf.cells[ax2 + ay2 * w].index) + i32(get_con(as, dir2))
            if ai2 < 0 || ai2 >= chf.span_count {
                continue
            }
            if chf.areas[ai2] != area {
                continue
            }
            nr2 := src_reg[ai2]
            if nr2 != 0 && nr2 != r {
                ar = nr2
                break
            }
        }
        if ar != 0 {
            src_reg[ci] = 0
            continue
        }

        count += 1

        // Expand neighbours
        for dir in 0..<4 {
            if get_con(cs, dir) == RC_NOT_CONNECTED {
                continue
            }
            ax := cx + get_dir_offset_x(dir)
            ay := cy + get_dir_offset_y(dir)
            if ax < 0 || ay < 0 || ax >= w || ay >= h {
                continue
            }
            ai := i32(u32(chf.cells[ax + ay * w].index)) + i32(get_con(cs, dir))
            if chf.areas[ai] != area {
                continue
            }
            if chf.dist[ai] >= lev && src_reg[ai] == 0 {
                src_reg[ai] = r
                src_dist[ai] = 0
                append(stack, Level_Stack_Entry{ax, ay, ai})
            }
        }
    }

    return count > 0
}

// Expand regions to fill gaps
@(optimization_mode="none")
expand_regions :: proc(max_iter: i32, level: u16, chf: ^Compact_Heightfield,
                      src_reg, src_dist: []u16, stack: ^[dynamic]Level_Stack_Entry,
                      fill_stack: bool) {
    w := chf.width
    h := chf.height

    if fill_stack {
        // Find cells revealed by the raised level
        clear(stack)
        for y in 0..<h {
            for x in 0..<w {
                c := &chf.cells[x + y * w]
                for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                    if chf.dist[i] >= level && src_reg[i] == 0 && chf.areas[i] != RC_NULL_AREA {
                        append(stack, Level_Stack_Entry{x, y, i32(i)})
                    }
                }
            }
        }
    } else {
        // Mark all cells which already have a region
        for j in 0..<len(stack) {
            i := stack[j].index
            if i >= 0 && src_reg[i] != 0 {
                stack[j].index = -1
            }
        }
    }

    dirty_entries := make([dynamic]Dirty_Entry, 0, 256)
    defer delete(dirty_entries)

    iter: i32 = 0

    for len(stack) > 0 {
        failed := 0
        clear(&dirty_entries)

        for j in 0..<len(stack) {
            x := stack[j].x
            y := stack[j].y
            i := stack[j].index
            if i < 0 {
                failed += 1
                continue
            }

            r := src_reg[i]
            d2: u16 = 0xffff
            area := chf.areas[i]
            s := &chf.spans[i]
            for dir in 0..<4 {
                if get_con(s, dir) == RC_NOT_CONNECTED {
                    continue
                }
                ax := x + get_dir_offset_x(dir)
                ay := y + get_dir_offset_y(dir)
                if ax < 0 || ay < 0 || ax >= w || ay >= h {
                    continue
                }
                ai := i32(u32(chf.cells[ax + ay * w].index)) + i32(get_con(s, dir))
                if ai < 0 || ai >= chf.span_count {
                    continue
                }
                if chf.areas[ai] != area {
                    continue
                }
                if src_reg[ai] > 0 && (src_reg[ai] & RC_BORDER_REG) == 0 {
                    if i32(src_dist[ai]) + 2 < i32(d2) {
                        r = src_reg[ai]
                        d2 = src_dist[ai] + 2
                    }
                }
            }
            if r != 0 {
                stack[j].index = -1 // mark as used
                append(&dirty_entries, Dirty_Entry{i32(i), r, d2})
            } else {
                failed += 1
            }
        }

        // Copy entries that differ between src and dst to keep them in sync
        for entry in dirty_entries {
            src_reg[entry.index] = entry.region
            src_dist[entry.index] = entry.distance2
        }

        if failed == len(stack) {
            break
        }

        if level > 0 {
            iter += 1
            if iter >= max_iter {
                break
            }
        }
    }
}

// Paint rectangular region
paint_rect_region :: proc(minx, maxx, miny, maxy: i32, reg_id: u16,
                         chf: ^Compact_Heightfield, src_reg: []u16) {
    w := chf.width
    for y in miny..<maxy {
        for x in minx..<maxx {
            c := &chf.cells[x + y * w]
            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                if chf.areas[i] != RC_NULL_AREA {
                    src_reg[i] = reg_id
                }
            }
        }
    }
}

// Sort cells by level for level-set processing
@(optimization_mode="none")
sort_cells_by_level :: proc(start_level: u16, chf: ^Compact_Heightfield, src_reg: []u16,
                           nb_stacks: u32, stacks: [][dynamic]Level_Stack_Entry,
                           log_levels_per_stack: u32) {
    w := chf.width
    h := chf.height
    start_level := start_level >> log_levels_per_stack

    for j in 0..<nb_stacks {
        clear(&stacks[j])
    }

    // Put all cells in the level range into the appropriate stacks
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                if chf.areas[i] == RC_NULL_AREA || src_reg[i] != 0 {
                    continue
                }

                level := u16(chf.dist[i]) >> log_levels_per_stack
                sid := i32(start_level) - i32(level)
                if sid >= i32(nb_stacks) {
                    continue
                }
                if sid < 0 {
                    sid = 0
                }

                append(&stacks[sid], Level_Stack_Entry{x, y, i32(i)})
            }
        }
    }
}

// Append stacks for level processing
append_stacks :: proc(src_stack: [dynamic]Level_Stack_Entry, dst_stack: ^[dynamic]Level_Stack_Entry,
                     src_reg: []u16) {
    for entry in src_stack {
        i := entry.index
        if i < 0 || src_reg[i] != 0 {
            continue
        }
        append(dst_stack, entry)
    }
}

// Remove adjacent duplicate neighbours
remove_adjacent_neighbours :: proc(reg: ^Region) {
    // Remove adjacent duplicates
    if len(reg.connections) <= 1 {
        return
    }

    // Use slice.unique to remove consecutive duplicates
    unique_slice := slice.unique(reg.connections[:])

    // Check wrap-around: if last element equals first element (circular case)
    if len(unique_slice) > 1 && unique_slice[len(unique_slice)-1] == unique_slice[0] {
        resize(&reg.connections, len(unique_slice)-1)
    } else {
        resize(&reg.connections, len(unique_slice))
    }
}

// Replace neighbour in region connections
replace_neighbour :: proc(reg: ^Region, old_id, new_id: u16) {
    nei_changed := false
    for i in 0..<len(reg.connections) {
        if reg.connections[i] == i32(old_id) {
            reg.connections[i] = i32(new_id)
            nei_changed = true
        }
    }
    for i in 0..<len(reg.floors) {
        if reg.floors[i] == i32(old_id) {
            reg.floors[i] = i32(new_id)
        }
    }
    if nei_changed {
        remove_adjacent_neighbours(reg)
    }
}

// Check if two regions can merge
can_merge_with_region :: proc(rega, regb: ^Region) -> bool {
    if rega.area_type != regb.area_type {
        return false
    }
    n := slice.count(rega.connections[:], i32(regb.id))
    if n > 1 {
        return false
    }
    if slice.contains(rega.floors[:], i32(regb.id)) {
        return false
    }
    return true
}

// Add unique floor region
add_unique_floor_region :: proc(reg: ^Region, n: i32) {
    if slice.contains(reg.floors[:], n) {
        return
    }
    append(&reg.floors, n)
}

// Merge two regions
merge_regions :: proc(rega, regb: ^Region) -> bool {
    aid := rega.id
    bid := regb.id

    // Duplicate current neighbourhood
    acon := make([dynamic]i32, len(rega.connections))
    defer delete(acon)
    copy(acon[:], rega.connections[:])
    bcon := &regb.connections

    // Find insertion point on A
    insa := -1
    for val, i in acon {
        if val == i32(bid) {
            insa = i
            break
        }
    }
    if insa == -1 {
        return false
    }

    // Find insertion point on B
    insb := -1
    for val, i in bcon {
        if val == i32(aid) {
            insb = i
            break
        }
    }
    if insb == -1 {
        return false
    }

    // Merge neighbours
    clear(&rega.connections)
    for i := 0; i < len(acon) - 1; i += 1 {
        append(&rega.connections, acon[(insa + 1 + i) % len(acon)])
    }

    for i := 0; i < len(bcon) - 1; i += 1 {
        append(&rega.connections, bcon[(insb + 1 + i) % len(bcon)])
    }

    remove_adjacent_neighbours(rega)

    for j in 0..<len(regb.floors) {
        add_unique_floor_region(rega, regb.floors[j])
    }
    rega.span_count += regb.span_count
    regb.span_count = 0
    clear(&regb.connections)

    return true
}

// Check if region is connected to border
is_region_connected_to_border :: proc(reg: ^Region) -> bool {
    // Region is connected to border if one of the neighbours is null id
    for i in 0..<len(reg.connections) {
        if reg.connections[i] == 0 {
            return true
        }
    }
    return false
}

// Check if edge is solid
is_solid_edge :: proc(chf: ^Compact_Heightfield, src_reg: []u16,
                     x, y, i: i32, dir: int) -> bool {
    s := &chf.spans[i]
    r: u16 = 0
    if get_con(s, dir) != RC_NOT_CONNECTED {
        ax := x + get_dir_offset_x(dir)
        ay := y + get_dir_offset_y(dir)
        if ax >= 0 && ay >= 0 && ax < chf.width && ay < chf.height {
            ai := i32(chf.cells[ax + ay * chf.width].index) + i32(get_con(s, dir))
            if ai >= 0 && ai < i32(len(src_reg)) {
                r = src_reg[ai]
            }
        }
    }
    if r == src_reg[i] {
        return false
    }
    return true
}

// Walk contour to find region connections - renamed to avoid conflict with contour.odin
@(optimization_mode="none")
walk_contour_for_region :: proc(x_in, y_in, i_in: i32, dir_in: int, chf: ^Compact_Heightfield,
                    src_reg: []u16, cont: ^[dynamic]i32) {
    x, y, i := x_in, y_in, i_in
    dir := dir_in
    start_dir := dir
    starti := i

    ss := &chf.spans[i]
    cur_reg: u16 = 0
    if get_con(ss, dir) != RC_NOT_CONNECTED {
        ax := x + get_dir_offset_x(dir)
        ay := y + get_dir_offset_y(dir)
        if ax >= 0 && ay >= 0 && ax < chf.width && ay < chf.height {
            ai := i32(chf.cells[ax + ay * chf.width].index) + i32(get_con(ss, dir))
            if ai >= 0 && ai < i32(len(src_reg)) {
                cur_reg = src_reg[ai]
            }
        }
    }
    append(cont, i32(cur_reg))

    iter := 0
    max_iter := 40000 // Prevent infinite loops
    for iter < max_iter {
        iter += 1
        s := &chf.spans[i]

        if is_solid_edge(chf, src_reg, x, y, i, dir) {
            // Choose the edge corner
            r: u16 = 0
            if get_con(s, dir) != RC_NOT_CONNECTED {
                ax := x + get_dir_offset_x(dir)
                ay := y + get_dir_offset_y(dir)
                if ax >= 0 && ay >= 0 && ax < chf.width && ay < chf.height {
                    ai := i32(chf.cells[ax + ay * chf.width].index) + i32(get_con(s, dir))
                    if ai >= 0 && ai < i32(len(src_reg)) {
                        r = src_reg[ai]
                    }
                }
            }
            if r != cur_reg {
                cur_reg = r
                append(cont, i32(cur_reg))
            }

            dir = (dir + 1) & 0x3  // Rotate CW
        } else {
            ni: i32 = -1
            nx := x + get_dir_offset_x(dir)
            ny := y + get_dir_offset_y(dir)
            if get_con(s, dir) != RC_NOT_CONNECTED {
                if nx >= 0 && ny >= 0 && nx < chf.width && ny < chf.height {
                    nc := &chf.cells[nx + ny * chf.width]
                    ni = i32(nc.index) + i32(get_con(s, dir))
                }
            }
            if ni == -1 {
                // Should not happen
                return
            }
            x = nx
            y = ny
            i = ni
            dir = (dir + 3) & 0x3    // Rotate CCW
        }

        if starti == i && start_dir == dir {
            break
        }
    }
    // remove consecutive duplicates
    arr := slice.unique(cont[:])
    // Check wrap-around: if last element equals first element (circular case)
    if len(arr) > 1 && arr[len(arr)-1] == arr[0] {
        resize(cont, len(arr)-1)
    } else {
        resize(cont, len(arr))
    }
}

// Add unique connection
add_unique_connection :: proc(reg: ^Region, n: i32) {
    if slice.contains(reg.connections[:], n) {
        return
    }
    append(&reg.connections, n)
}

// Merge and filter regions
@(optimization_mode="none")
merge_and_filter_regions :: proc(min_region_area, merge_region_size: i32,
                               max_region_id: ^u16, chf: ^Compact_Heightfield,
                               src_reg: []u16, overlaps: ^[dynamic]i32) -> bool {
    w := chf.width
    h := chf.height

    nreg := i32(max_region_id^) + 1
    regions := make([dynamic]Region, nreg)
    defer {
        for i in 0..<len(regions) {
            delete(regions[i].connections)
            delete(regions[i].floors)
        }
        delete(regions)
    }

    // Construct regions
    for i in 0..<nreg {
        regions[i] = Region{
            id = u16(i),
            ymin = 0xffff,
            ymax = 0,
        }
    }

    // Find edge of a region and find connections around the contour
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                r := src_reg[i]
                if r == 0 || r >= u16(nreg) {
                    continue
                }

                reg := &regions[r]
                reg.span_count += 1

                // Update floors
                for j in u32(c.index)..<u32(c.index) + u32(c.count) {
                    if i == j {
                        continue
                    }
                    floor_id := src_reg[j]
                    if floor_id == 0 || floor_id >= u16(nreg) {
                        continue
                    }
                    if floor_id == r {
                        reg.overlap = true
                    }
                    add_unique_floor_region(reg, i32(floor_id))
                }

                // Have found contour
                if len(reg.connections) > 0 {
                    continue
                }

                reg.area_type = chf.areas[i]

                // Check if this cell is next to a border
                ndir := -1
                for dir in 0..<4 {
                    if is_solid_edge(chf, src_reg, x, y, i32(i), dir) {
                        ndir = dir
                        break
                    }
                }

                if ndir != -1 {
                    // The cell is at border
                    // Walk around the contour to find all the neighbours
                    walk_contour_for_region(x, y, i32(i), ndir, chf, src_reg, &reg.connections)
                }
            }
        }
    }

    // Remove too small regions
    stack := make([dynamic]i32, 0, 32)
    defer delete(stack)
    trace := make([dynamic]i32, 0, 32)
    defer delete(trace)

    for &reg, i in regions {
        if reg.id == 0 || (reg.id & RC_BORDER_REG) != 0 {
            continue
        }
        if reg.span_count == 0 {
            continue
        }
        if reg.visited {
            continue
        }

        // Count the total size of all the connected regions
        // Also keep track of the regions connects to a tile border
        connects_to_border := false
        span_count := i32(0)
        clear(&stack)
        clear(&trace)

        reg.visited = true
        append(&stack, i32(i))

        for len(stack) > 0 {
            // Pop
            ri := pop(&stack)

            creg := &regions[ri]

            span_count += creg.span_count
            append(&trace, ri)

            for j in 0..<len(creg.connections) {
                if (u16(creg.connections[j]) & RC_BORDER_REG) != 0 {
                    connects_to_border = true
                    continue
                }
                neireg := &regions[creg.connections[j]]
                if neireg.visited {
                    continue
                }
                if neireg.id == 0 || (neireg.id & RC_BORDER_REG) != 0 {
                    continue
                }
                // Visit
                append(&stack, i32(neireg.id))
                neireg.visited = true
            }
        }

        // If the accumulated regions size is too small, remove it
        // Do not remove areas which connect to tile borders
        // as their size cannot be estimated correctly and removing them
        // can potentially remove necessary areas
        if span_count < min_region_area && !connects_to_border {
            // Kill all visited regions
            for j in trace {
                regions[j].span_count = 0
                regions[j].id = 0
            }
        }
    }

    // Merge too small regions to neighbour regions
    merge_count := 0
    for {
        merge_count = 0
        for i in 0..<nreg {
            reg := &regions[i]
            if reg.id == 0 || (reg.id & RC_BORDER_REG) != 0 {
                continue
            }
            if reg.overlap {
                continue
            }
            if reg.span_count == 0 {
                continue
            }

            // Check to see if the region should be merged
            if reg.span_count > merge_region_size && is_region_connected_to_border(reg) {
                continue
            }

            // Small region with more than 1 connection
            // Or region which is not connected to a border at all
            // Find smallest neighbour region that connects to this one
            smallest := 0xfffffff
            merge_id := reg.id
            for j in 0..<len(reg.connections) {
                if (u16(reg.connections[j]) & RC_BORDER_REG) != 0 {
                    continue
                }
                mreg := &regions[reg.connections[j]]
                if mreg.id == 0 || (mreg.id & RC_BORDER_REG) != 0 || mreg.overlap {
                    continue
                }
                if int(mreg.span_count) < smallest &&
                   can_merge_with_region(reg, mreg) &&
                   can_merge_with_region(mreg, reg) {
                    smallest = int(mreg.span_count)
                    merge_id = mreg.id
                }
            }
            // Found new id
            if merge_id != reg.id {
                old_id := reg.id
                target := &regions[merge_id]

                // Merge neighbours
                if merge_regions(target, reg) {
                    // Fixup regions pointing to current region
                    for j in 0..<nreg {
                        if regions[j].id == 0 || (regions[j].id & RC_BORDER_REG) != 0 {
                            continue
                        }
                        // If another region was already merged into current region
                        // change the nid of the previous region too
                        if regions[j].id == old_id {
                            regions[j].id = merge_id
                        }
                        // Replace the current region with the new one if the
                        // current regions is neighbour
                        replace_neighbour(&regions[j], old_id, merge_id)
                    }
                    merge_count += 1
                }
            }
        }

        if merge_count == 0 {
            break
        }
    }

    // Compress region Ids
    for &reg in regions {
        reg.remap = false
        if reg.id == 0 {
            continue // Skip nil regions
        }
        if (reg.id & RC_BORDER_REG) != 0 {
            continue // Skip external regions
        }
        reg.remap = true
    }

    reg_id_gen: u16 = 0
    for i in 0..<nreg {
        if !regions[i].remap {
            continue
        }
        old_id := regions[i].id
        reg_id_gen += 1
        new_id := reg_id_gen
        for j := i; j < nreg; j += 1 {
            if regions[j].id == old_id {
                regions[j].id = new_id
                regions[j].remap = false
            }
        }
    }
    max_region_id^ = reg_id_gen

    // Remap regions
    for i in 0..<chf.span_count {
        if (src_reg[i] & RC_BORDER_REG) == 0 {
            src_reg[i] = regions[src_reg[i]].id
        }
    }

    // Return regions that we found to be overlapping
    for i in 0..<nreg {
        if regions[i].overlap {
            append(overlaps, i32(regions[i].id))
        }
    }

    return true
}

// Build regions using watershed partitioning
build_regions :: proc(chf: ^Compact_Heightfield,
                        border_size, min_region_area, merge_region_area: i32) -> bool {
    w := chf.width
    h := chf.height

    // Handle empty compact heightfield
    if chf.span_count == 0 {
        return true
    }

    allocator := context.allocator
    buf := make([]u16, chf.span_count * 2, allocator)  // Need 2 buffers: reg and dist
    if buf == nil {
        log.errorf("rcBuildRegions: Out of memory 'tmp' (%d).", chf.span_count * 4)
        return false
    }
    defer delete(buf)

    LOG_NB_STACKS :: 3
    NB_STACKS :: 1 << LOG_NB_STACKS
    lvl_stacks: [NB_STACKS][dynamic]Level_Stack_Entry
    for i in 0..<NB_STACKS {
        lvl_stacks[i] = make([dynamic]Level_Stack_Entry, 0, 256)
    }
    defer {
        for i in 0..<NB_STACKS {
            delete(lvl_stacks[i])
        }
    }

    stack := make([dynamic]Level_Stack_Entry, 0, 256)
    defer delete(stack)

    src_reg := buf[:chf.span_count]
    src_dist := buf[chf.span_count:chf.span_count*2]

    // Initialize to 0
    slice.fill(src_reg, 0)
    slice.fill(src_dist, 0)

    region_id: u16 = 1
    level := (chf.max_distance + 1) & (~u16(1))

    // Calculate expand iterations based on distance field
    // More iterations for larger distance fields to ensure proper region expansion
    expand_iters := i32(8)
    if border_size > 0 {
        // Make sure border will not overflow
        bw := min(w, border_size)
        bh := min(h, border_size)

        // Paint regions
        paint_rect_region(0, bw, 0, h, region_id | RC_BORDER_REG, chf, src_reg)
        region_id += 1
        paint_rect_region(w - bw, w, 0, h, region_id | RC_BORDER_REG, chf, src_reg)
        region_id += 1
        paint_rect_region(0, w, 0, bh, region_id | RC_BORDER_REG, chf, src_reg)
        region_id += 1
        paint_rect_region(0, w, h - bh, h, region_id | RC_BORDER_REG, chf, src_reg)
        region_id += 1

    }

    chf.border_size = border_size

    sid := -1

    for level > 0 {
        level = level >= 2 ? level - 2 : 0
        sid = (sid + 1) & (NB_STACKS - 1)

        if sid == 0 {
            sort_cells_by_level(level, chf, src_reg, NB_STACKS, lvl_stacks[:], 1)
        } else {
            append_stacks(lvl_stacks[sid - 1], &lvl_stacks[sid], src_reg)
        }

        // Expand current regions until no empty connected cells found
        expand_regions(expand_iters, level, chf, src_reg, src_dist, &lvl_stacks[sid], false)

        // Mark new regions with IDs
        new_regions_count := 0
        for current in lvl_stacks[sid] {
            x := current.x
            y := current.y
            i := current.index
            if i >= 0 && src_reg[i] == 0 {
                if flood_region(x, y, i, level, region_id, chf, src_reg, src_dist, &stack) {
                    if region_id == 0xFFFF {
                        log.error("rcBuildRegions: Region ID overflow")
                        return false
                    }
                    new_regions_count += 1
                    region_id += 1
                }
            }
        }

    }

    // Expand current regions until no empty connected cells found
    expand_regions(expand_iters * 8, 0, chf, src_reg, src_dist, &stack, true)

    {
        // Merge regions and filter out small regions

        overlaps := make([dynamic]i32, 0, 32)
        defer delete(overlaps)
        chf.max_regions = region_id

        if !merge_and_filter_regions(min_region_area, merge_region_area, &chf.max_regions, chf, src_reg, &overlaps) {
            log.error("rcBuildRegions: Failed to merge and filter regions")
            return false
        }

        // If overlapping regions were found during merging, split those regions
        if len(overlaps) > 0 {
            log.errorf("rcBuildRegions: %d overlapping regions found during merge", len(overlaps))
            // In a complete implementation, we would handle overlapping regions here
            // For now, we log the issue but continue
        }
    }

    // Write the result out and validate
    assigned_spans := 0
    unassigned_spans := 0
    border_spans := 0
    unique_regions := make(map[u16]bool)
    defer delete(unique_regions)

    for i in 0..<chf.span_count {
        chf.spans[i].reg = src_reg[i]

        if src_reg[i] == 0 {
            unassigned_spans += 1
        } else if (src_reg[i] & RC_BORDER_REG) != 0 {
            border_spans += 1
        } else {
            assigned_spans += 1
            unique_regions[src_reg[i]] = true
        }
    }

    log.infof("Region building complete: %d unique regions, %d assigned spans, %d border spans, %d unassigned spans",
              len(unique_regions), assigned_spans, border_spans, unassigned_spans)

    if len(unique_regions) > 10 {
        log.warnf("WARNING: Found %d disconnected regions - this may cause pathfinding failures!", len(unique_regions))
    }

    if unassigned_spans > 0 {
        log.warnf("Warning: %d spans were not assigned to any region", unassigned_spans)
    }

    return true
}

// Build regions using monotone partitioning
build_regions_monotone :: proc(chf: ^Compact_Heightfield,
                                 border_size, min_region_area, merge_region_area: i32) -> bool {
    w := chf.width
    h := chf.height
    id: u16 = 1

    allocator := context.allocator
    src_reg := make([]u16, chf.span_count, allocator)
    if src_reg == nil {
        log.errorf("rcBuildRegionsMonotone: Out of memory 'src' (%d).", chf.span_count)
        return false
    }
    defer delete(src_reg)
    // slice.fill(src_reg, 0) // unnecessary

    nsweeps := max(chf.width, chf.height)
    sweeps := make([]Sweep_Span, nsweeps, allocator)
    if sweeps == nil {
        log.errorf("rcBuildRegionsMonotone: Out of memory 'sweeps' (%d).", nsweeps)
        return false
    }
    defer delete(sweeps)

    // Mark border regions
    if border_size > 0 {
        // Make sure border will not overflow
        bw := min(w, border_size)
        bh := min(h, border_size)
        // Paint regions
        paint_rect_region(0, bw, 0, h, id | RC_BORDER_REG, chf, src_reg)
        id += 1
        paint_rect_region(w - bw, w, 0, h, id | RC_BORDER_REG, chf, src_reg)
        id += 1
        paint_rect_region(0, w, 0, bh, id | RC_BORDER_REG, chf, src_reg)
        id += 1
        paint_rect_region(0, w, h - bh, h, id | RC_BORDER_REG, chf, src_reg)
        id += 1
    }

    chf.border_size = border_size

    prev := make([dynamic]i32, 256)
    defer delete(prev)

    // Sweep one line at a time
    for y in border_size..<h - border_size {
        // Collect spans from this row
        resize(&prev, int(id) + 1)
        slice.fill(prev[:], 0)
        rid: u16 = 1

        for x in border_size..<w - border_size {
            c := &chf.cells[x + y * w]

            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                s := &chf.spans[i]
                if chf.areas[i] == RC_NULL_AREA {
                    continue
                }

                // -x
                previd: u16 = 0
                if get_con(s, 0) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(0)
                    ay := y + get_dir_offset_y(0)
                    if ax >= 0 && ay >= 0 && ax < w && ay < h {
                        ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, 0))
                        if (src_reg[ai] & RC_BORDER_REG) == 0 && chf.areas[i] == chf.areas[ai] {
                            previd = src_reg[ai]
                        }
                    }
                }

                if previd == 0 {
                    previd = rid
                    rid += 1
                    sweeps[previd].rid = previd
                    sweeps[previd].ns = 0
                    sweeps[previd].nei = 0
                }

                // -y
                if get_con(s, 3) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(3)
                    ay := y + get_dir_offset_y(3)
                    if ax >= 0 && ay >= 0 && ax < w && ay < h {
                        ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, 3))
                        if src_reg[ai] != 0 && (src_reg[ai] & RC_BORDER_REG) == 0 && chf.areas[i] == chf.areas[ai] {
                            nr := src_reg[ai]
                            if sweeps[previd].nei == 0 || sweeps[previd].nei == nr {
                                sweeps[previd].nei = nr
                                sweeps[previd].ns += 1
                                prev[nr] += 1
                            } else {
                                sweeps[previd].nei = RC_NULL_NEI
                            }
                        }
                    }
                }

                src_reg[i] = previd
            }
        }

        // Create unique ID
        for i in 1..<int(rid) {
            if sweeps[i].nei != RC_NULL_NEI && sweeps[i].nei != 0 &&
               prev[sweeps[i].nei] == i32(sweeps[i].ns) {
                sweeps[i].id = sweeps[i].nei
            } else {
                sweeps[i].id = id
                id += 1
            }
        }

        // Remap IDs
        for x in border_size..<w - border_size {
            c := &chf.cells[x + y * w]

            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                if src_reg[i] > 0 && src_reg[i] < rid {
                    src_reg[i] = sweeps[src_reg[i]].id
                }
            }
        }
    }

    {
        // Merge regions and filter out small regions
        overlaps := make([dynamic]i32)
        defer delete(overlaps)
        chf.max_regions = id
        if !merge_and_filter_regions(min_region_area, merge_region_area, &chf.max_regions, chf, src_reg, &overlaps) {
            return false
        }

        // Monotone partitioning does not generate overlapping regions
    }

    // Store the result out
    for i in 0..<chf.span_count {
        chf.spans[i].reg = src_reg[i]
    }

    return true
}

// Merge and filter layer regions
merge_and_filter_layer_regions :: proc(min_region_area: i32,
                                      max_region_id: ^u16, chf: ^Compact_Heightfield,
                                      src_reg: []u16) -> bool {
    w := chf.width
    h := chf.height

    nreg := i32(max_region_id^) + 1
    regions := make([dynamic]Region, nreg)
    defer {
        for i in 0..<len(regions) {
            delete(regions[i].connections)
            delete(regions[i].floors)
        }
        delete(regions)
    }

    // Construct regions
    for i in 0..<nreg {
        regions[i] = Region{
            id = u16(i),
            ymin = 0xffff,
            ymax = 0,
        }
    }

    // Find region neighbours and overlapping regions
    lregs := make([dynamic]i32, 0, 32)
    defer delete(lregs)

    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]

            clear(&lregs)

            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                s := &chf.spans[i]
                area := chf.areas[i]
                ri := src_reg[i]
                if ri == 0 || ri >= u16(nreg) {
                    continue
                }
                reg := &regions[ri]

                reg.span_count += 1
                reg.area_type = area

                reg.ymin = min(reg.ymin, s.y)
                reg.ymax = max(reg.ymax, s.y)

                // Collect all region layers
                append(&lregs, i32(ri))

                // Update neighbours
                for dir in 0..<4 {
                    if get_con(s, dir) != RC_NOT_CONNECTED {
                        ax := x + get_dir_offset_x(dir)
                        ay := y + get_dir_offset_y(dir)
                        if ax >= 0 && ay >= 0 && ax < w && ay < h {
                            ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, dir))
                            rai := src_reg[ai]
                            if rai > 0 && rai < u16(nreg) && rai != ri {
                                add_unique_connection(reg, i32(rai))
                            }
                            if (rai & RC_BORDER_REG) != 0 {
                                reg.connects_to_border = true
                            }
                        }
                    }
                }
            }

            // Update overlapping regions
            for i in 0..<len(lregs) - 1 {
                for j in i + 1..<len(lregs) {
                    if lregs[i] != lregs[j] {
                        ri := &regions[lregs[i]]
                        rj := &regions[lregs[j]]
                        add_unique_floor_region(ri, lregs[j])
                        add_unique_floor_region(rj, lregs[i])
                    }
                }
            }
        }
    }

    // Create 2D layers from regions
    layer_id: u16 = 1

    for i in 0..<nreg {
        regions[i].id = 0
    }

    // Merge monotone regions to create non-overlapping areas
    stack := make([dynamic]i32, 0, 32)
    defer delete(stack)

    for i in 1..<nreg {
        root := &regions[i]
        // Skip already visited
        if root.id != 0 {
            continue
        }

        // Start search
        root.id = layer_id

        clear(&stack)
        append(&stack, i32(i))

        for len(stack) > 0 {
            // Pop front
            reg := &regions[stack[0]]
            for j in 0..<len(stack) - 1 {
                stack[j] = stack[j + 1]
            }
            resize(&stack, len(stack) - 1)

            ncons := len(reg.connections)
            for j in 0..<ncons {
                nei := reg.connections[j]
                regn := &regions[nei]
                // Skip already visited
                if regn.id != 0 {
                    continue
                }
                // Skip if different area type, do not connect regions with different area type
                if reg.area_type != regn.area_type {
                    continue
                }
                // Skip if the neighbour is overlapping root region
                if slice.contains(root.floors[:], nei) {
                    continue
                }

                // Deepen
                append(&stack, nei)

                // Mark layer id
                regn.id = layer_id
                // Merge current layers to root
                for k in 0..<len(regn.floors) {
                    add_unique_floor_region(root, regn.floors[k])
                }
                root.ymin = min(root.ymin, regn.ymin)
                root.ymax = max(root.ymax, regn.ymax)
                root.span_count += regn.span_count
                regn.span_count = 0
                root.connects_to_border = root.connects_to_border || regn.connects_to_border
            }
        }

        layer_id += 1
    }

    // Remove small regions
    for i in 0..<nreg {
        if regions[i].span_count > 0 && regions[i].span_count < min_region_area && !regions[i].connects_to_border {
            reg := regions[i].id
            for j in 0..<nreg {
                if regions[j].id == reg {
                    regions[j].id = 0
                }
            }
        }
    }

    // Compress region Ids
    for i in 0..<nreg {
        regions[i].remap = false
        if regions[i].id == 0 {
            continue // Skip nil regions
        }
        if (regions[i].id & RC_BORDER_REG) != 0 {
            continue // Skip external regions
        }
        regions[i].remap = true
    }

    reg_id_gen: u16 = 0
    for i in 0..<nreg {
        if !regions[i].remap {
            continue
        }
        old_id := regions[i].id
        reg_id_gen += 1
        new_id := reg_id_gen
        for j := i; j < nreg; j += 1 {
            if regions[j].id == old_id {
                regions[j].id = new_id
                regions[j].remap = false
            }
        }
    }
    max_region_id^ = reg_id_gen

    // Remap regions
    for i in 0..<chf.span_count {
        if (src_reg[i] & RC_BORDER_REG) == 0 {
            src_reg[i] = regions[src_reg[i]].id
        }
    }

    return true
}

// Build layer regions for multi-story environments
build_layer_regions :: proc(chf: ^Compact_Heightfield,
                              border_size, min_region_area: i32) -> bool {
    w := chf.width
    h := chf.height
    id: u16 = 1

    allocator := context.allocator
    src_reg := make([]u16, chf.span_count, allocator)
    if src_reg == nil {
        log.errorf("rcBuildLayerRegions: Out of memory 'src' (%d).", chf.span_count)
        return false
    }
    defer delete(src_reg)
    slice.fill(src_reg, 0)

    nsweeps := max(chf.width, chf.height)
    sweeps := make([]Sweep_Span, nsweeps, allocator)
    if sweeps == nil {
        log.errorf("rcBuildLayerRegions: Out of memory 'sweeps' (%d).", nsweeps)
        return false
    }
    defer delete(sweeps)

    // Mark border regions
    if border_size > 0 {
        // Make sure border will not overflow
        bw := min(w, border_size)
        bh := min(h, border_size)
        // Paint regions
        paint_rect_region(0, bw, 0, h, id | RC_BORDER_REG, chf, src_reg)
        id += 1
        paint_rect_region(w - bw, w, 0, h, id | RC_BORDER_REG, chf, src_reg)
        id += 1
        paint_rect_region(0, w, 0, bh, id | RC_BORDER_REG, chf, src_reg)
        id += 1
        paint_rect_region(0, w, h - bh, h, id | RC_BORDER_REG, chf, src_reg)
        id += 1
    }

    chf.border_size = border_size

    prev := make([dynamic]i32, 256)
    defer delete(prev)

    // Sweep one line at a time
    for y in border_size..<h - border_size {
        // Collect spans from this row
        resize(&prev, int(id) + 1)
        slice.fill(prev[:], 0)
        rid: u16 = 1

        for x in border_size..<w - border_size {
            c := &chf.cells[x + y * w]

            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                s := &chf.spans[i]
                if chf.areas[i] == RC_NULL_AREA {
                    continue
                }

                // -x
                previd: u16 = 0
                if get_con(s, 0) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(0)
                    ay := y + get_dir_offset_y(0)
                    if ax >= 0 && ay >= 0 && ax < w && ay < h {
                        ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, 0))
                        if (src_reg[ai] & RC_BORDER_REG) == 0 && chf.areas[i] == chf.areas[ai] {
                            previd = src_reg[ai]
                        }
                    }
                }

                if previd == 0 {
                    previd = rid
                    rid += 1
                    sweeps[previd].rid = previd
                    sweeps[previd].ns = 0
                    sweeps[previd].nei = 0
                }

                // -y
                if get_con(s, 3) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(3)
                    ay := y + get_dir_offset_y(3)
                    if ax >= 0 && ay >= 0 && ax < w && ay < h {
                        ai := u32(chf.cells[ax + ay * w].index) + u32(get_con(s, 3))
                        if src_reg[ai] != 0 && (src_reg[ai] & RC_BORDER_REG) == 0 && chf.areas[i] == chf.areas[ai] {
                            nr := src_reg[ai]
                            if sweeps[previd].nei == 0 || sweeps[previd].nei == nr {
                                sweeps[previd].nei = nr
                                sweeps[previd].ns += 1
                                prev[nr] += 1
                            } else {
                                sweeps[previd].nei = RC_NULL_NEI
                            }
                        }
                    }
                }

                src_reg[i] = previd
            }
        }

        // Create unique ID
        for i in 1..<int(rid) {
            if sweeps[i].nei != RC_NULL_NEI && sweeps[i].nei != 0 &&
               prev[sweeps[i].nei] == i32(sweeps[i].ns) {
                sweeps[i].id = sweeps[i].nei
            } else {
                sweeps[i].id = id
                id += 1
            }
        }

        // Remap IDs
        for x in border_size..<w - border_size {
            c := &chf.cells[x + y * w]

            for i in u32(c.index)..<u32(c.index) + u32(c.count) {
                if src_reg[i] > 0 && src_reg[i] < rid {
                    src_reg[i] = sweeps[src_reg[i]].id
                }
            }
        }
    }

    // Merge monotone regions to layers and remove small regions
    chf.max_regions = id
    if !merge_and_filter_layer_regions(min_region_area, &chf.max_regions, chf, src_reg) {
        return false
    }

    // Store the result out
    for i in 0..<chf.span_count {
        chf.spans[i].reg = src_reg[i]
    }

    return true
}
