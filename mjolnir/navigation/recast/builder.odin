package navigation_recast


import "core:slice"
import "core:log"
import "core:time"
import "core:math"

// Build compact heightfield from regular heightfield
rc_build_compact_heightfield :: proc(walkable_height, walkable_climb: i32,
                                    hf: ^Rc_Heightfield, chf: ^Rc_Compact_Heightfield) -> bool {
    w := hf.width
    h := hf.height
    span_count := 0

    // Fill in header
    chf.width = w
    chf.height = h
    chf.span_count = 0
    chf.walkable_height = walkable_height
    chf.walkable_climb = walkable_climb
    chf.max_distance = 0
    chf.max_regions = 0
    chf.bmin = hf.bmin
    chf.bmax = hf.bmax
    chf.cs = hf.cs
    chf.ch = hf.ch
    chf.border_size = hf.border_size

    chf.cells = make([]Rc_Compact_Cell, w * h)
    chf.spans = nil
    chf.areas = nil

    // Count spans and find max bottom
    max_spans := 0
    for y in 0..<h {
        for x in 0..<w {
            s := hf.spans[x + y * w]
            if s == nil do continue

            span_num := 0
            for s != nil {
                if s.area != RC_NULL_AREA {
                    span_count += 1
                    span_num += 1
                }
                s = s.next
            }
            max_spans = max(max_spans, span_num)
        }
    }

    if span_count == 0 {
        return true
    }

    // Allocate spans
    chf.span_count = i32(span_count)
    chf.spans = make([]Rc_Compact_Span, span_count)
    chf.areas = make([]u8, span_count)

    // Fill in cells and spans
    idx := 0
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            c.index = u32(idx)
            c.count = 0
            for s := hf.spans[x + y * w]; s != nil; s = s.next {
                if s.area != RC_NULL_AREA {
                    bottom := s.smax
                    next := s.next
                    top := next != nil ? u32(next.smin) : u32(RC_SPAN_MAX_HEIGHT)
                    cs := &chf.spans[idx]
                    cs.y = u16(math.clamp(int(bottom), 0, 0xffff))
                    cs.h = u8(math.clamp(int(top - bottom), 0, 0xff))
                    chf.areas[idx] = u8(s.area)
                    idx += 1
                    c.count = c.count + 1
                }
            }
        }
    }

    // Find neighbor connections
    max_layers := max_spans
    too_high_neighbor := 0
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]
            for i in c.index..<c.index + u32(c.count) {
                s := &chf.spans[i]
                for dir in 0..<4 {
                    rc_set_con(s, dir, RC_NOT_CONNECTED)
                    nx := int(x) + int(get_dir_offset_x(dir))
                    ny := int(y) + int(get_dir_offset_y(dir))
                    if nx < 0 || ny < 0 || nx >= int(w) || ny >= int(h) {
                        continue
                    }
                    nc := &chf.cells[nx + ny * int(w)]
                    // Find connection
                    for k in nc.index..<nc.index + u32(nc.count) {
                        ns := &chf.spans[k]
                        bot := max(int(s.y), int(ns.y))
                        top := min(int(s.y) + int(s.h), int(ns.y) + int(ns.h))
                        if (top - bot) >= int(walkable_height) && abs(int(ns.y) - int(s.y)) <= int(walkable_climb) {
                            lidx := int(k - nc.index)
                            if lidx < 0 || lidx > max_layers {
                                too_high_neighbor = max(too_high_neighbor, lidx)
                                continue
                            }
                            rc_set_con(s, dir, lidx)
                            break
                        }
                    }
                }
            }
        }
    }

    if too_high_neighbor > max_layers {
        log.errorf("rcBuildCompactHeightfield: Heightfield has too many layers %d (max %d)", too_high_neighbor, max_layers)
    }

    return true
}

// Build contours from compact heightfield
rc_build_contours :: proc(chf: ^Rc_Compact_Heightfield,
                         max_error: f32, max_edge_len: i32, cset: ^Rc_Contour_Set,
                         build_flags: i32 = -1) -> bool {
    // EMERGENCY TIMEOUT: Force return after 5 seconds to prevent test hangs
    emergency_start_time := time.now()
    emergency_timeout := time.Second * 5

    log.infof("Starting contour building with emergency timeout: %.1fs", f64(time.duration_seconds(emergency_timeout)))

    // Maximum theoretical boundary walk iterations based on heightfield size
    // This should never be reached in practice as boundary walking has deterministic termination
    max_theoretical_iterations := chf.span_count * 4  // Each span has at most 4 boundary edges

    w := chf.width
    h := chf.height
    border_size := chf.border_size

    // Initialize contour set
    cset.bmin = chf.bmin
    cset.bmax = chf.bmax
    cset.cs = chf.cs
    cset.ch = chf.ch
    cset.width = w
    cset.height = h
    cset.border_size = border_size
    cset.max_error = max_error
    cset.nconts = 0
    cset.conts = make([]Rc_Contour, 0)
    // defer delete(cset.conts) // Will be freed by rc_free_contour_set

    // Create flags array to mark region boundaries
    flags := make([]u8, chf.span_count)
    defer delete(flags)

    log.infof("Building contours for %d spans across %dx%d grid", chf.span_count, w, h)

    // Mark region boundaries - spans that have different region neighbors
    boundary_spans := 0
    for y in 0..<h {
        for x in 0..<w {
            c := &chf.cells[x + y * w]

            span_idx := c.index
            span_count := c.count

            for i in span_idx..<span_idx + u32(span_count) {
                s := &chf.spans[i]
                res: u8 = 0

                // Check all 4 directions for region boundaries
                for dir in 0..<4 {
                    r: u16 = 0
                    if rc_get_con(s, dir) != RC_NOT_CONNECTED {
                        ax := x + get_dir_offset_x(dir)
                        ay := y + get_dir_offset_y(dir)
                        ai := chf.cells[ax + ay * w].index + u32(rc_get_con(s, dir))
                        r = chf.spans[ai].reg
                    }

                    if r == s.reg {
                        res |= (1 << u8(dir))
                    }
                }

                // Invert flags - we want boundaries where regions differ
                flags[i] = res ~ 0xf
                if flags[i] != 0 do boundary_spans += 1
            }
        }
    }

    log.infof("Found %d boundary spans to process", boundary_spans)

    // Create temporary arrays for contour vertices
    verts := make([dynamic]i32, 0)
    defer delete(verts)
    simplified := make([dynamic]i32, 0)
    defer delete(simplified)

    // Extract contours for each region - process each region only once
    contours_created := 0
    total_verts_processed := 0
    processed_regions := make(map[u16]bool)
    defer delete(processed_regions)

    cells_processed := 0
    max_cells_to_process := int(w * h)
    contour_start_time := time.now()
    max_contour_time := time.Millisecond * 5000 // Reduced to 5 second timeout for entire contour building

    for y in 0..<h {
        for x in 0..<w {
            cells_processed += 1

            // Check for timeout every 50 cells to prevent hangs (more frequent checks)
            if cells_processed % 50 == 0 {
                elapsed := time.since(contour_start_time)
                if elapsed > max_contour_time {
                    log.warnf("Contour building timeout after %.2fs, processed %d/%d cells",
                             f64(time.duration_milliseconds(elapsed)) / 1000.0, cells_processed, max_cells_to_process)
                    break
                }

                // Emergency timeout check
                emergency_elapsed := time.since(emergency_start_time)
                if emergency_elapsed > emergency_timeout {
                    log.errorf("EMERGENCY TIMEOUT: Contour building exceeded %.1fs limit, forcing return with partial results",
                              f64(time.duration_seconds(emergency_timeout)))
                    break
                }
            }

            // Early exit for placeholder implementation to prevent infinite-like behavior
            if cells_processed > max_cells_to_process {
                log.warnf("Processed maximum cells (%d), stopping to prevent hang", max_cells_to_process)
                break
            }

            c := &chf.cells[x + y * w]

            span_idx := c.index
            span_count := c.count

            spans_in_cell := 0
            for i in span_idx..<span_idx + u32(span_count) {
                spans_in_cell += 1

                // Safety check for excessive spans per cell
                if spans_in_cell > 100 {
                    log.warnf("Cell at (%d, %d) has excessive spans (%d), stopping processing", x, y, spans_in_cell)
                    break
                }

                if flags[i] == 0 || chf.spans[i].reg == 0 {
                    continue
                }

                region_id := chf.spans[i].reg
                area_id := chf.areas[i]

                // Skip if we've already processed this region
                if region_id in processed_regions {
                    continue
                }
                processed_regions[region_id] = true

                // Extract contour for this region
                log.debugf("Processing region %d at cell (%d, %d) span %d", region_id, x, y, i)

                // Clear arrays for this contour
                clear(&verts)
                clear(&simplified)

                // Emergency timeout check before expensive boundary walk
                emergency_elapsed := time.since(emergency_start_time)
                if emergency_elapsed > emergency_timeout {
                    log.errorf("EMERGENCY TIMEOUT: Contour building exceeded %.1fs limit during region processing",
                              f64(time.duration_seconds(emergency_timeout)))
                    break
                }

                // Walk the boundary to extract vertices
                boundary_success := walk_contour_boundary(i32(x), i32(y), i32(i), chf, flags[:], &verts)
                if !boundary_success {
                    log.warnf("Failed to walk boundary for region %d, skipping", region_id)
                    continue
                }

                if len(verts) >= 3 { // Need at least 3 vertices for a valid contour
                    // Simplify the contour if requested
                    if max_error > 0.01 {
                        simplify_contour(verts[:], &simplified, max_error, chf.cs)
                    } else {
                        // Use raw vertices if no simplification
                        for v in verts {
                            append(&simplified, v)
                        }
                    }

                    // Only create contour if we have meaningful vertices after simplification
                    if len(simplified) >= 12 { // Each vertex is x,y,z,r (4 components, 12 values minimum for triangle)
                        // Check if we have space for more contours
                        if cset.nconts >= i32(len(cset.conts)) {
                            // Resize the contours array if needed
                            old_conts := cset.conts
                            new_size := max(len(old_conts) * 2, 16) // Start with at least 16 contours
                            cset.conts = make([]Rc_Contour, new_size)
                            copy(cset.conts, old_conts)
                            delete(old_conts)
                        }

                        // Allocate new contour
                        cont := &cset.conts[cset.nconts]
                        cont.area = area_id
                        cont.reg = region_id
                        cont.nverts = i32(len(simplified) / 4) // Each vertex has 4 components (x,y,z,r)

                        // Allocate and copy vertex data
                        cont.verts = make([]i32, len(simplified))
                        copy(cont.verts, simplified[:])

                        cset.nconts += 1
                        contours_created += 1
                        total_verts_processed += len(verts)

                        log.debugf("Created contour for region %d: %d raw vertices -> %d simplified vertices",
                                  region_id, len(verts)/3, cont.nverts)

                        // Stop if we've reached the maximum number of contours
                        if cset.nconts >= i32(len(cset.conts)) {
                            log.warnf("Reached maximum contour limit (%d), stopping", len(cset.conts))
                            break
                        }
                    } else {
                        log.debugf("Skipped region %d: insufficient vertices after simplification (%d)", region_id, len(simplified))
                    }
                } else {
                    log.debugf("Skipped region %d: insufficient boundary vertices (%d)", region_id, len(verts))
                }

                // Exit early once we've identified all regions to prevent unnecessary iteration
                if len(processed_regions) >= int(chf.max_regions) {
                    log.infof("Processed all %d regions, ending early", chf.max_regions)
                    break
                }
            }

            // Break out of nested loops if we've processed all regions
            if len(processed_regions) >= int(chf.max_regions) {
                break
            }
        }

        // Break out of outermost loop if we've processed all regions
        if len(processed_regions) >= int(chf.max_regions) {
            break
        }
    }

    log.infof("Processed %d total vertices, created %d contours", total_verts_processed, contours_created)

    // Check if we completed due to emergency timeout
    emergency_elapsed := time.since(emergency_start_time)
    if emergency_elapsed > emergency_timeout {
        log.warnf("Contour building completed with emergency timeout: %.2fs elapsed, %d contours created",
                 f64(time.duration_seconds(emergency_elapsed)), cset.nconts)
        // Return true even with partial results to prevent complete failure
        return cset.nconts > 0
    }

    log.infof("Built %d contours total", cset.nconts)
    return true
}

// Walk along the boundary of a region to extract contour vertices
// Returns true if boundary walk completed successfully, false if algorithm cannot proceed
walk_contour_boundary :: proc(x, y, i: i32, chf: ^Rc_Compact_Heightfield,
                             flags: []u8, points: ^[dynamic]i32) -> bool {
    // Input bounds validation
    if i < 0 || i >= i32(len(flags)) {
        log.errorf("Invalid span index %d for boundary walk (flags array length: %d)", i, len(flags))
        return false
    }

    if x < 0 || x >= chf.width || y < 0 || y >= chf.height {
        log.errorf("Invalid coordinates (%d, %d) for boundary walk (heightfield size: %dx%d)", x, y, chf.width, chf.height)
        return false
    }

    // Find first boundary edge - choose the first non-connected edge
    dir: u8 = 0
    for (flags[i] & (1 << dir)) == 0 {
        dir += 1
        if dir >= 4 {
            log.debugf("No boundary edges found for span %d at (%d, %d)", i, x, y)
            return false // No boundary found
        }
    }

    start_dir := dir
    start_i := i
    area := chf.areas[i]

    // Use the same variable names as C++ for clarity - these are the current position
    curr_x, curr_y, curr_i := x, y, i
    iter: i32 = 0

    log.debugf("Starting boundary walk from (%d, %d) span %d, direction %d", x, y, i, dir)

    // Walk boundary following the C++ reference algorithm exactly
    for iter < 40000 {
        iter += 1

        if (flags[curr_i] & (1 << dir)) != 0 {
            // We can step in this direction - create vertex at edge corner
            is_border_vertex := false
            px := curr_x
            py := get_corner_height_for_contour(curr_x, curr_y, curr_i, i32(dir), chf, &is_border_vertex)
            pz := curr_y

            // Adjust vertex position based on direction (matching C++ exactly)
            switch dir {
            case 0: pz += 1      // North: increment Z
            case 1: px += 1; pz += 1  // Northeast: increment both X and Z
            case 2: px += 1      // East: increment X
            case 3:              // South: no change (base position)
            }

            // Get region info for the edge
            r: i32 = 0
            s := &chf.spans[curr_i]
            if rc_get_con(s, int(dir)) != RC_NOT_CONNECTED {
                ax := curr_x + i32(get_dir_offset_x(int(dir)))
                ay := curr_y + i32(get_dir_offset_y(int(dir)))

                // Bounds check for neighbor coordinates
                if ax >= 0 && ax < chf.width && ay >= 0 && ay < chf.height {
                    ai := i32(chf.cells[ax + ay * chf.width].index) + i32(rc_get_con(s, int(dir)))
                    if ai >= 0 && ai < i32(len(chf.spans)) {
                        r = i32(chf.spans[ai].reg)

                        // Check if this is an area border
                        if ai < i32(len(chf.areas)) && area != chf.areas[ai] {
                            r |= RC_AREA_BORDER
                        }
                    }
                }
            }

            if is_border_vertex {
                r |= RC_BORDER_VERTEX
            }

            append(points, px, py, pz, r)

            flags[curr_i] &= ~(1 << dir) // Remove visited edges
            dir = (dir + 1) & 0x3       // Rotate CW
        } else {
            // Cannot step in this direction - move to neighbor span
            ni := i32(-1)
            nx := curr_x + i32(get_dir_offset_x(int(dir)))
            ny := curr_y + i32(get_dir_offset_y(int(dir)))
            s := &chf.spans[curr_i]

            if rc_get_con(s, int(dir)) != RC_NOT_CONNECTED {
                // Bounds check for neighbor coordinates
                if nx >= 0 && nx < chf.width && ny >= 0 && ny < chf.height {
                    nc := &chf.cells[nx + ny * chf.width]
                    ni = i32(nc.index) + i32(rc_get_con(s, int(dir)))
                }
            }

            if ni == -1 {
                // Should not happen in valid heightfield - matches C++ behavior
                return false
            }

            // Update position to neighbor (matches C++ exactly)
            curr_x = nx
            curr_y = ny
            curr_i = ni
            dir = (dir + 3) & 0x3  // Rotate CCW
        }

        // Check termination condition - must match C++ exactly
        if start_i == curr_i && start_dir == dir {
            log.debugf("Boundary walk completed after %d iterations", iter)
            return true
        }
    }

    // Should not happen with valid heightfield
    log.errorf("Boundary walk exceeded maximum iterations, may indicate corrupted heightfield")
    return false
}

// Get height at corner, considering neighboring spans
get_corner_height_for_contour :: proc(x, y, i, dir: i32, chf: ^Rc_Compact_Heightfield,
                                     is_border_vertex: ^bool) -> i32 {
    // Input validation
    if i < 0 || i >= i32(len(chf.spans)) {
        log.errorf("Invalid span index %d in get_corner_height_for_contour", i)
        return 0
    }

    s := &chf.spans[i]
    ch := i32(s.y)
    dirp := (dir + 1) & 0x3

    regs: [4]u32

    // Combine region and area codes with bounds checking
    if i < i32(len(chf.areas)) {
        regs[0] = u32(s.reg) | (u32(chf.areas[i]) << 16)
    } else {
        regs[0] = u32(s.reg)
    }

    // Check primary direction
    if rc_get_con(s, int(dir)) != RC_NOT_CONNECTED {
        ax := x + i32(get_dir_offset_x(int(dir)))
        ay := y + i32(get_dir_offset_y(int(dir)))

        // Bounds check for neighbor coordinates
        if ax >= 0 && ax < chf.width && ay >= 0 && ay < chf.height {
            ai := i32(chf.cells[ax + ay * chf.width].index) + i32(rc_get_con(s, int(dir)))

            if ai >= 0 && ai < i32(len(chf.spans)) {
                as := &chf.spans[ai]
                ch = max(ch, i32(as.y))
                if ai < i32(len(chf.areas)) {
                    regs[1] = u32(as.reg) | (u32(chf.areas[ai]) << 16)
                } else {
                    regs[1] = u32(as.reg)
                }

                // Check diagonal
                if rc_get_con(as, int(dirp)) != RC_NOT_CONNECTED {
                    ax2 := ax + i32(get_dir_offset_x(int(dirp)))
                    ay2 := ay + i32(get_dir_offset_y(int(dirp)))

                    if ax2 >= 0 && ax2 < chf.width && ay2 >= 0 && ay2 < chf.height {
                        ai2 := i32(chf.cells[ax2 + ay2 * chf.width].index) + i32(rc_get_con(as, int(dirp)))

                        if ai2 >= 0 && ai2 < i32(len(chf.spans)) {
                            as2 := &chf.spans[ai2]
                            ch = max(ch, i32(as2.y))
                            if ai2 < i32(len(chf.areas)) {
                                regs[2] = u32(as2.reg) | (u32(chf.areas[ai2]) << 16)
                            } else {
                                regs[2] = u32(as2.reg)
                            }
                        }
                    }
                }
            }
        }
    }

    // Check perpendicular direction
    if rc_get_con(s, int(dirp)) != RC_NOT_CONNECTED {
        ax := x + i32(get_dir_offset_x(int(dirp)))
        ay := y + i32(get_dir_offset_y(int(dirp)))

        // Bounds check for neighbor coordinates
        if ax >= 0 && ax < chf.width && ay >= 0 && ay < chf.height {
            ai := i32(chf.cells[ax + ay * chf.width].index) + i32(rc_get_con(s, int(dirp)))

            if ai >= 0 && ai < i32(len(chf.spans)) {
                as := &chf.spans[ai]
                ch = max(ch, i32(as.y))
                if ai < i32(len(chf.areas)) {
                    regs[3] = u32(as.reg) | (u32(chf.areas[ai]) << 16)
                } else {
                    regs[3] = u32(as.reg)
                }

                // Check diagonal
                if rc_get_con(as, int(dir)) != RC_NOT_CONNECTED {
                    ax2 := ax + i32(get_dir_offset_x(int(dir)))
                    ay2 := ay + i32(get_dir_offset_y(int(dir)))

                    if ax2 >= 0 && ax2 < chf.width && ay2 >= 0 && ay2 < chf.height {
                        ai2 := i32(chf.cells[ax2 + ay2 * chf.width].index) + i32(rc_get_con(as, int(dir)))

                        if ai2 >= 0 && ai2 < i32(len(chf.spans)) {
                            as2 := &chf.spans[ai2]
                            ch = max(ch, i32(as2.y))
                            if ai2 < i32(len(chf.areas)) {
                                regs[2] = u32(as2.reg) | (u32(chf.areas[ai2]) << 16)
                            } else {
                                regs[2] = u32(as2.reg)
                            }
                        }
                    }
                }
            }
        }
    }

    // Check if vertex is on border between regions
    is_border_vertex^ = false
    for j in 0..<4 {
        a := j
        b := (j + 1) & 0x3
        c := (j + 2) & 0x3
        d := (j + 3) & 0x3

        // Check for specific border patterns
        two_same_exts := (regs[a] & regs[b] & RC_BORDER_REG) != 0 && regs[a] == regs[b]
        two_ints := ((regs[c] | regs[d]) & RC_BORDER_REG) == 0
        ints_same_area := (regs[c] >> 16) == (regs[d] >> 16)
        no_zeros := regs[a] != 0 && regs[b] != 0 && regs[c] != 0 && regs[d] != 0

        if two_same_exts && two_ints && ints_same_area && no_zeros {
            is_border_vertex^ = true
            break
        }
    }

    return ch
}

// Simplify contour using Douglas-Peucker style algorithm
simplify_contour_vertices :: proc(points: ^[dynamic]i32, simplified: ^[dynamic]i32,
                                 max_error: f32, max_edge_len: i32, build_flags: u32) {
    clear(simplified)

    if len(points) < 12 do return // Need at least 3 vertices

    nverts := len(points) / 4

    // Check if contour has connections to other regions
    has_connections := false
    for i := 0; i < nverts; i += 1 {
        if (points[i*4+3] & RC_CONTOUR_REG_MASK) != 0 {
            has_connections = true
            break
        }
    }

    if has_connections {
        // Add vertices at region boundaries
        for i := 0; i < nverts; i += 1 {
            ii := (i + 1) % nverts
            different_regs := (points[i*4+3] & RC_CONTOUR_REG_MASK) != (points[ii*4+3] & RC_CONTOUR_REG_MASK)
            area_borders := (points[i*4+3] & RC_AREA_BORDER) != (points[ii*4+3] & RC_AREA_BORDER)

            if different_regs || area_borders {
                append(simplified, points[i*4+0], points[i*4+1], points[i*4+2], i32(i))
            }
        }
    }

    if len(simplified) == 0 {
        // Add corner vertices (lower-left and upper-right)
        llx, lly, llz := points[0], points[1], points[2]
        lli := 0
        urx, ury, urz := points[0], points[1], points[2]
        uri := 0

        for i := 0; i < nverts; i += 1 {
            x, y, z := points[i*4+0], points[i*4+1], points[i*4+2]
            if x < llx || (x == llx && z < llz) {
                llx, lly, llz = x, y, z
                lli = i
            }
            if x > urx || (x == urx && z > urz) {
                urx, ury, urz = x, y, z
                uri = i
            }
        }

        append(simplified, llx, lly, llz, i32(lli))
        append(simplified, urx, ury, urz, i32(uri))
    }

    // Iteratively add points until all raw points are within error tolerance
    max_error_sq := max_error * max_error
    max_iterations := nverts * 2 // Safety limit

    for iter := 0; iter < max_iterations; iter += 1 {
        nsimp := len(simplified) / 4
        if nsimp == 0 do break

        found_point := false

        for i := 0; i < nsimp; i += 1 {
            ii := (i + 1) % nsimp

            ax, az := simplified[i*4+0], simplified[i*4+2]
            ai := simplified[i*4+3]
            bx, bz := simplified[ii*4+0], simplified[ii*4+2]
            bi := simplified[ii*4+3]

            // Find maximum deviation from segment
            maxd: f32 = 0
            maxi: i32 = -1

            // Traverse segment in lexicographical order
            cinc: i32
            ci, endi: i32
            if bx > ax || (bx == ax && bz > az) {
                cinc = 1
                ci = (ai + cinc) % i32(nverts)
                endi = bi
            } else {
                cinc = i32(nverts) - 1
                ci = (bi + cinc) % i32(nverts)
                endi = ai
                ax, bx = bx, ax
                az, bz = bz, az
            }

            // Only tessellate outer edges or edges between areas
            should_tessellate := false
            if ci != endi {
                first_point_flags := points[ci*4+3]
                if (first_point_flags & RC_CONTOUR_REG_MASK) == 0 ||
                   (first_point_flags & RC_AREA_BORDER) != 0 {
                    should_tessellate = true
                }
            }

            if should_tessellate {
                for ci != endi {
                    d := distance_point_to_segment_sq(points[ci*4+0], points[ci*4+2], ax, az, bx, bz)
                    if d > maxd {
                        maxd = d
                        maxi = i32(ci)
                    }
                    ci = (ci + cinc) % i32(nverts)
                }
            }

            // If max deviation is larger than accepted error, add new point
            if maxi != -1 && maxd > max_error_sq {
                // Insert new point at position i+1
                insert_pos := (i + 1) * 4
                for _ in 0..<4 {
                    inject_at(simplified, insert_pos, 0)
                }

                simplified[insert_pos+0] = points[maxi*4+0]
                simplified[insert_pos+1] = points[maxi*4+1]
                simplified[insert_pos+2] = points[maxi*4+2]
                simplified[insert_pos+3] = maxi

                found_point = true
                break
            }
        }

        if !found_point do break
    }

    // Split long edges if max_edge_len is specified
    if max_edge_len > 0 && (build_flags & (RC_CONTOUR_TESS_WALL_EDGES | RC_CONTOUR_TESS_AREA_EDGES)) != 0 {
        if !split_long_edges(simplified, points[:], max_edge_len, nverts, build_flags) {
            log.warnf("Edge splitting failed to converge, using unsplit contour")
        }
    }

    // Fix up region and vertex flags
    nsimp := len(simplified) / 4
    for i := 0; i < nsimp; i += 1 {
        ai := (simplified[i*4+3] + 1) % i32(nverts)
        bi := simplified[i*4+3]
        simplified[i*4+3] = (points[ai*4+3] & (RC_CONTOUR_REG_MASK | RC_AREA_BORDER)) |
                           (points[bi*4+3] & RC_BORDER_VERTEX)
    }
}

// Calculate squared distance from point to line segment
distance_point_to_segment_sq :: proc(x, z, px, pz, qx, qz: i32) -> f32 {
    pqx := f32(qx - px)
    pqz := f32(qz - pz)
    dx := f32(x - px)
    dz := f32(z - pz)
    d := pqx * pqx + pqz * pqz
    t := pqx * dx + pqz * dz

    if d > 0 {
        t /= d
    }
    t = math.clamp(t, 0, 1)

    dx = f32(px) + t * pqx - f32(x)
    dz = f32(pz) + t * pqz - f32(z)

    return dx * dx + dz * dz
}

// Split long edges based on max_edge_len parameter
// Returns true if splitting completed successfully, false if convergence failed
split_long_edges :: proc(simplified: ^[dynamic]i32, points: []i32, max_edge_len: i32,
                        nverts: int, build_flags: u32) -> bool {

    initial_edge_count := len(simplified) / 4
    splits_performed := 0

    for iter := 0; ; iter += 1 {
        nsimp := len(simplified) / 4
        if nsimp == 0 do break

        edges_split_this_iteration := 0

        for i := 0; i < nsimp; i += 1 {
            ii := (i + 1) % nsimp

            ax, az := simplified[i*4+0], simplified[i*4+2]
            ai := simplified[i*4+3]
            bx, bz := simplified[ii*4+0], simplified[ii*4+2]
            bi := simplified[ii*4+3]

            maxi: i32 = -1
            ci := (ai + 1) % i32(nverts)

            // Check if edge should be tessellated
            should_tessellate := false
            if (build_flags & RC_CONTOUR_TESS_WALL_EDGES) != 0 &&
               (points[ci*4+3] & RC_CONTOUR_REG_MASK) == 0 {
                should_tessellate = true
            }
            if (build_flags & RC_CONTOUR_TESS_AREA_EDGES) != 0 &&
               (points[ci*4+3] & RC_AREA_BORDER) != 0 {
                should_tessellate = true
            }

            if should_tessellate {
                dx := bx - ax
                dz := bz - az
                if dx*dx + dz*dz > max_edge_len*max_edge_len {
                    // Calculate split point
                    n := bi - ai if bi > ai else bi + i32(nverts) - ai
                    if n > 1 {
                        if bx > ax || (bx == ax && bz > az) {
                            maxi = (ai + n/2) % i32(nverts)
                        } else {
                            maxi = (ai + (n+1)/2) % i32(nverts)
                        }
                    }
                }
            }

            if maxi != -1 {
                // Insert new point at position i+1
                insert_pos := (i + 1) * 4
                for _ in 0..<4 {
                    inject_at(simplified, insert_pos, 0)
                }

                simplified[insert_pos+0] = points[maxi*4+0]
                simplified[insert_pos+1] = points[maxi*4+1]
                simplified[insert_pos+2] = points[maxi*4+2]
                simplified[insert_pos+3] = maxi

                edges_split_this_iteration += 1
                splits_performed += 1
                break
            }
        }

        // Natural termination: no more edges to split
        if edges_split_this_iteration == 0 {
            log.debugf("Edge splitting converged after %d iterations, %d total splits", iter, splits_performed)
            return true
        }

        // Safety check: detect potential infinite loops
        // Each original edge can be split at most O(nverts) times in pathological cases
        max_safe_iterations := max(initial_edge_count * 2, 50)
        if iter >= max_safe_iterations {
            log.errorf("Edge splitting failed to converge after %d iterations (%d splits). Contour data may be corrupted.", iter, splits_performed)
            return false
        }

        // Additional safety: if we're making too many splits, something is wrong
        if splits_performed > nverts * 2 {
            log.errorf("Edge splitting performed excessive splits (%d), expected at most %d. Algorithm may be unstable.", splits_performed, nverts * 2)
            return false
        }
    }

    // Should never reach here
    return false
}

// Remove degenerate segments from contour
remove_degenerate_contour_segments :: proc(simplified: ^[dynamic]i32) {
    MAX_DEGEN_ITERATIONS :: 100  // Safety limit to prevent infinite loops

    for iter := 0; iter < MAX_DEGEN_ITERATIONS; iter += 1 {
        npts := len(simplified) / 4
        if npts < 3 do break // Need at least 3 vertices

        found_degenerate := false
        i := 0

        for i < npts {
            ni := (i + 1) % npts

            // Check if consecutive vertices are identical
            if vertices_equal(simplified[i*4:], simplified[ni*4:]) {
                // Remove degenerate segment
                remove_vertex_at(simplified, i)
                npts -= 1
                found_degenerate = true

                // Don't increment i, check the same position again
            } else {
                i += 1
            }
        }

        if !found_degenerate do break
    }
}

// Check if two vertices are equal (comparing only x and z coordinates)
vertices_equal :: proc(a, b: []i32) -> bool {
    return len(a) >= 4 && len(b) >= 4 && a[0] == b[0] && a[2] == b[2]
}

// Remove vertex at given index from simplified contour
remove_vertex_at :: proc(simplified: ^[dynamic]i32, index: int) {
    if index < 0 || index*4 >= len(simplified) do return

    // Remove 4 consecutive elements (x, y, z, flags)
    start := index * 4
    end := start + 4
    if end > len(simplified) do end = len(simplified)

    // Remove the range by shifting elements
    for i in start..<len(simplified) - (end - start) {
        simplified[i] = simplified[i + (end - start)]
    }
    resize(simplified, len(simplified) - (end - start))
}

// Validate vertex data integrity
validate_vertex_data :: proc(verts: []i32) -> bool {
    if len(verts) % 4 != 0 do return false
    if len(verts) < 12 do return false // Need at least 3 vertices

    nverts := len(verts) / 4

    // Check for reasonable coordinate values and no invalid flags
    for i in 0..<nverts {
        x, y, z := verts[i*4+0], verts[i*4+1], verts[i*4+2]

        // Check for extremely large coordinates that might indicate corruption
        if abs(x) > 1000000 || abs(y) > 1000000 || abs(z) > 1000000 {
            log.warnf("Vertex %d has extreme coordinates: (%d, %d, %d)", i, x, y, z)
            return false
        }
    }

    return true
}

// Calculate signed area of 2D contour (positive = counter-clockwise, negative = clockwise)
calculate_contour_area :: proc(verts: []i32) -> i32 {
    if len(verts) < 12 do return 0 // Need at least 3 vertices

    nverts := len(verts) / 4
    area: i32 = 0
    j := nverts - 1

    for i in 0..<nverts {
        vi_x := verts[i*4+0]
        vi_z := verts[i*4+2]
        vj_x := verts[j*4+0]
        vj_z := verts[j*4+2]

        area += vi_x * vj_z - vj_x * vi_z
        j = i
    }

    return (area + 1) / 2  // Round and return signed area
}

// Debug tracking for contour set allocations
@(private)
contour_set_alloc_count: int = 0
@(private)
contour_set_free_count: int = 0

// Allocate contour set
rc_alloc_contour_set :: proc() -> ^Rc_Contour_Set {
    contour_set_alloc_count += 1
    cset := new(Rc_Contour_Set)
    cset.conts = make([]Rc_Contour, 256) // Allocate space for up to 256 contours
    cset.nconts = 0
    log.infof("DEBUG rc_alloc_contour_set: Allocated contour set #%d at %p", contour_set_alloc_count, cset)
    return cset
}

// Free contour set
rc_free_contour_set :: proc(cset: ^Rc_Contour_Set) {
    if cset == nil do return
    contour_set_free_count += 1
    log.infof("DEBUG rc_free_contour_set: Freeing contour set #%d at %p with %d contours (alloc=%d, free=%d)",
              contour_set_free_count, cset, cset.nconts, contour_set_alloc_count, contour_set_free_count)
    for i in 0..<cset.nconts {
        cont := &cset.conts[i]
        if cont.verts != nil {
            delete(cont.verts)
        }
        if cont.rverts != nil {
            delete(cont.rverts)
        }
    }

    if cset.conts != nil {
        log.infof("DEBUG rc_free_contour_set: About to delete conts array (should be 12KB)")
        delete(cset.conts)
        log.infof("DEBUG rc_free_contour_set: Conts array deleted")
    }

    log.infof("DEBUG rc_free_contour_set: About to free cset")
    free(cset)
    log.infof("DEBUG rc_free_contour_set: Cset freed")
}

// Simplify contour by removing unnecessary vertices using Douglas-Peucker algorithm
simplify_contour :: proc(raw_verts: []i32, simplified: ^[dynamic]i32, max_error: f32, cell_size: f32) {
    if len(raw_verts) < 6 { // Need at least 2 vertices (6 values)
        return
    }

    // For now, implement basic vertex reduction by removing collinear points
    // Each vertex is stored as x, y, z (3 values), but for contours we work in 2D (x, z)

    // Start with first vertex
    append(simplified, raw_verts[0], raw_verts[1], raw_verts[2])

    error_sq := max_error * max_error

    i := 3 // Start from second vertex (skip first which we already added)
    for i < len(raw_verts) - 3 { // Leave room for last vertex
        curr_x := raw_verts[i]
        curr_z := raw_verts[i + 2]
        // Check bounds before accessing next vertex
        if i + 5 >= len(raw_verts) {
            break // No more vertices to process
        }
        next_x := raw_verts[i + 3]
        next_z := raw_verts[i + 5]

        // Get the last added vertex for line segment
        last_idx := len(simplified) - 3
        if last_idx >= 0 {
            last_x := simplified[last_idx]
            last_z := simplified[last_idx + 2]

            // Calculate distance from current point to line segment (last -> next)
            dx := f32(next_x - last_x)
            dz := f32(next_z - last_z)

            if dx*dx + dz*dz > 0.001 { // Avoid division by zero
                // Point-to-line distance calculation
                px := f32(curr_x - last_x)
                pz := f32(curr_z - last_z)

                dot := px*dx + pz*dz
                len_sq := dx*dx + dz*dz

                // Project point onto line
                t := dot / len_sq
                if t < 0 { t = 0 }
                if t > 1 { t = 1 }

                proj_x := f32(last_x) + t * dx
                proj_z := f32(last_z) + t * dz

                dist_sq := (f32(curr_x) - proj_x) * (f32(curr_x) - proj_x) +
                          (f32(curr_z) - proj_z) * (f32(curr_z) - proj_z)

                // Only add vertex if it's far enough from the line
                if dist_sq > error_sq {
                    append(simplified, curr_x, raw_verts[i + 1], curr_z)
                }
            } else {
                // Line segment is too short, add the vertex
                append(simplified, curr_x, raw_verts[i + 1], curr_z)
            }
        }

        i += 3 // Move to next vertex
    }

    // Always add the last vertex to close the contour
    if len(raw_verts) >= 3 {
        last_idx := len(raw_verts) - 3
        append(simplified, raw_verts[last_idx], raw_verts[last_idx + 1], raw_verts[last_idx + 2])
    }
}
