package navigation_recast

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:mem"

RC_MAX_LAYER_ID :: 255
RC_NULL_LAYER_ID :: 255
RC_MAX_LAYERS_DEF :: 63  // Must be ≤ 255
RC_MAX_NEIS_DEF :: 16
MAX_STACK :: 64
RC_NULL_LAYER :: u8(0xff)  // Unassigned layer marker

// Modernized Layer Region for heightfield layers (distinct from types.odin)
Heightfield_Layer_Region :: struct {
    overlapping_layers: [dynamic]u8,    // Overlapping layer IDs
    neighbors: [dynamic]u8,             // Neighbor region IDs
    height_bounds: [2]u16,              // [ymin, ymax] using array for bounds
    layer_id: u8,                       // Assigned layer ID (0xff = unassigned)
    is_base: bool,                      // Flag: true if base region, false if merged
}

Layer_Sweep_Span :: struct {
    sample_count: u16,  // ns - number samples
    region_id: u8,      // id - region id (set in second phase)
    neighbor_id: u8,    // nei - neighbour id (0xff = invalid)
}

// Utility function: add unique value to dynamic slice
add_unique :: proc(a: ^[dynamic]u8, v: u8) -> bool {
    if slice.contains(a[:], v) do return true
    append(a, v)
    return true
}

@(private)
add_unique_capped :: proc(a: ^[dynamic]u8, v: u8, max_size: int) -> bool {
    if slice.contains(a[:], v) do return true
    if len(a) >= max_size do return false
    append(a, v)
    return true
}

// Using vector swizzling-like syntax for bounds checking
ranges_overlap :: proc(a_bounds, b_bounds: [2]u16) -> bool {
    return !(a_bounds.x > b_bounds.y || a_bounds.y < b_bounds.x)
}

// Vector-based bounds utilities
@(private)
expand_bounds :: proc(bounds: ^[2]u16, value: u16) {
    bounds.x = min(bounds.x, value)  // ymin
    bounds.y = max(bounds.y, value)  // ymax
}

@(private)
bounds_size :: proc(bounds: [2]u16) -> u16 {
    return bounds.y - bounds.x
}

create_heightfield_layer_set :: proc() -> [dynamic]Heightfield_Layer {
  return make([dynamic]Heightfield_Layer)
}

// Free heightfield layer set
free_heightfield_layer_set :: proc(lset: [dynamic]Heightfield_Layer) {
  for layer in lset {
    delete(layer.heights)
    delete(layer.areas)
    delete(layer.cons)
  }
  delete(lset)
}

// Modernized layer building with better error handling
build_heightfield_layers :: proc(
    chf: ^Compact_Heightfield,
    border_size: i32,
    walkable_height: i32,
) -> (result: [dynamic]Heightfield_Layer, success: bool) {
    if chf == nil {
        log.error("build_heightfield_layers: nil compact heightfield")
        return {}, false
    }

    dimensions := [2]i32{chf.width, chf.height}  // Using array for dimensions
    span_count := i32(len(chf.spans))

    log.infof("build_heightfield_layers: %v cells, %d spans", dimensions, span_count)

    // Phase 1: Monotone region partitioning
    src_reg := make([]u8, span_count)
    defer delete(src_reg)

    if !partition_monotone_regions(chf, border_size, src_reg) {
        log.warn("build_heightfield_layers: Could not partition monotone regions (likely >255 regions)")
        return {}, false
    }

    // Count regions
    nregs := 0
    for reg in src_reg {
        if reg != RC_NULL_LAYER {
            nregs = max(nregs, int(reg) + 1)
        }
    }

    if nregs == 0 {
        log.warn("build_heightfield_layers: No regions found")
        return {}, true  // Empty result is valid
    }

    log.infof("build_heightfield_layers: %d regions", nregs)

    // Phase 2: Region analysis
    regions := make([]Heightfield_Layer_Region, nregs)
    defer {
        for &reg in regions {
            delete(reg.overlapping_layers)
            delete(reg.neighbors)
        }
        delete(regions)
    }

    if !analyze_regions(chf, src_reg, regions) {
        log.error("build_heightfield_layers: Could not analyze regions")
        return {}, false
    }

    // Phase 3: Layer assignment
    nlayers := assign_layers_dfs(regions)
    log.infof("build_heightfield_layers: %d layers", nlayers)

    // Phase 4: Layer merging
    nlayers = merge_layers(regions, walkable_height)
    log.infof("build_heightfield_layers: %d layers after merging", nlayers)

    // Phase 5: Layer compaction
    nlayers = compact_layer_ids(regions)
    log.infof("build_heightfield_layers: %d layers after compaction", nlayers)

    // Phase 6: Build layer data
    lset := make([dynamic]Heightfield_Layer, 0, nlayers)

    for layer_id in 0 ..< nlayers {
        if !build_single_layer(chf, src_reg, regions, u8(layer_id), border_size, &lset) {
            log.warnf("Failed to build layer %d", layer_id)
        }
    }

    log.infof("build_heightfield_layers: Built %d layers", len(lset))
    return lset, true
}

// Phase 1: Monotone region partitioning
partition_monotone_regions :: proc(
    chf: ^Compact_Heightfield,
    border_size: i32,
    src_reg: []u8,
) -> bool {
    w := chf.width
    h := chf.height

    // Initialize all regions as unassigned
    slice.fill(src_reg, 0xff)
    sweeps := make([dynamic]Layer_Sweep_Span)
    defer delete(sweeps)
    prev_count: [256]i32
    reg_id: u8 = 0

    // Process each row from border to h-border
    for y in border_size ..< (h - border_size) {
        // Reset previous count for this row
        slice.fill(prev_count[:reg_id], 0)
        sweep_id: u8 = 0
        clear(&sweeps)     // Start fresh for each row

        // Process each column from border to w-border
        for x in border_size ..< (w - border_size) {
            c := &chf.cells[x + y * w]

            // Process each span in this cell
            for i in c.index ..< c.index + u32(c.count) {
                if i >= u32(len(chf.spans)) || i >= u32(len(chf.areas)) {
                    continue
                }

                if chf.areas[i] == RC_NULL_AREA {
                    continue
                }

                sid: u8 = 0xff  // 0xff as invalid marker

                // Check connection in -X direction (direction 0)
                s := &chf.spans[i]
                if get_con(s, 0) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(0)
                    ay := y + get_dir_offset_y(0)
                    ai := chf.cells[ax + ay * w].index + u32(get_con(s, 0))
                    if ai < u32(len(chf.areas)) && ai < u32(len(src_reg)) &&
                       chf.areas[ai] != RC_NULL_AREA && src_reg[ai] != 0xff {
                        sid = src_reg[ai]  // Reuse existing sweep ID
                    }
                }

                // If no existing sweep found, create new one
                if sid == 0xff {
                    sid = sweep_id
                    sweep_id += 1

                    // Extend sweeps array if needed
                    for len(sweeps) <= int(sid) {
                        append(&sweeps, Layer_Sweep_Span{
                            sample_count = 0,
                            region_id = 0,      // Will be set in second phase
                            neighbor_id = 0xff, // uses 0xff for invalid
                        })
                    }

                    sweeps[sid].neighbor_id = 0xff
                    sweeps[sid].sample_count = 0
                }

                // Check connection in -Y direction (direction 3)
                if get_con(s, 3) != RC_NOT_CONNECTED {
                    ax := x + get_dir_offset_x(3)
                    ay := y + get_dir_offset_y(3)
                    ai := chf.cells[ax + ay * w].index + u32(get_con(s, 3))

                    if ai < u32(len(src_reg)) {
                        nr := src_reg[ai]
                        if nr != 0xff {
                            sweep := &sweeps[sid]

                            // Set neighbour when first valid neighbour is encountered
                            if sweep.sample_count == 0 {
                                sweep.neighbor_id = nr
                            }

                            if sweep.neighbor_id == nr {
                                // Update existing neighbour
                                sweep.sample_count += 1
                                prev_count[nr] += 1
                            } else {
                                // More than one neighbour - invalidate
                                sweep.neighbor_id = 0xff
                            }
                        }
                    }
                }

                // Store sweep ID in srcReg (first pass)
                src_reg[i] = sid
            }
        }

        // Create unique region IDs
        for i in 0..< int(sweep_id) {
            sweep := &sweeps[i]

            // If neighbour is set and there is only one continuous connection,
            // merge with previous region, else create new region
            if sweep.neighbor_id != 0xff &&
               prev_count[sweep.neighbor_id] == i32(sweep.sample_count) {
                sweep.region_id = sweep.neighbor_id
            } else {
                if reg_id == 255 {
                    log.warn("build_heightfield_layers: Region ID overflow (>255 regions not supported in layer system)")
                    return false
                }
                sweep.region_id = reg_id
                reg_id += 1
            }
        }

        // Remap local sweep IDs to region IDs (second pass)
        for x in border_size ..< (w - border_size) {
            c := &chf.cells[x + y * w]
            for i in c.index ..< c.index + u32(c.count) {
                if i >= u32(len(src_reg)) {
                    continue
                }
                if src_reg[i] != 0xff {
                    src_reg[i] = sweeps[src_reg[i]].region_id
                }
            }
        }
    }

    return true
}

// Phase 2: Region analysis and neighbor detection (Odin-idiomatic)
analyze_regions :: proc(
    chf: ^Compact_Heightfield,
    src_reg: []u8,
    regions: []Heightfield_Layer_Region,
) -> bool {
    w := chf.width
    h := chf.height

    // Initialize all regions
    for &reg in regions {
        reg.overlapping_layers = make([dynamic]u8)
        reg.neighbors = make([dynamic]u8)
        reg.height_bounds = {0xffff, 0}  // [ymin=max_value, ymax=0] for proper min/max tracking
        reg.layer_id = RC_NULL_LAYER
        reg.is_base = false
    }

    // Find region bounds and build neighbor relationships
    for y in 0 ..< h {
        for x in 0 ..< w {
            c := &chf.cells[x + y * w]

            // Collect regions in this cell
            local_regions := make([dynamic]u8)
            defer delete(local_regions)

            for i in c.index ..< c.index + u32(c.count) {
                if i >= u32(len(chf.spans)) ||
                   i >= u32(len(chf.areas)) ||
                   i >= u32(len(src_reg)) {
                    continue
                }

                if chf.areas[i] == RC_NULL_AREA {
                    continue
                }

                ri := src_reg[i]
                if ri == RC_NULL_LAYER || int(ri) >= len(regions) {
                    continue
                }

                s := &chf.spans[i]

                // Update region bounds using modernized approach
                reg := &regions[ri]
                // This tracks where spans START, not their full extent
                expand_bounds(&reg.height_bounds, s.y)
                expand_bounds(&reg.height_bounds, s.y)  // Yes, s.y for both!

                // Add to local regions list
                add_unique(&local_regions, ri)

                // Check 4-directional neighbors
                for dir in 0 ..< 4 {
                    if get_con(s, dir) != RC_NOT_CONNECTED {
                        ax := x + get_dir_offset_x(dir)
                        ay := y + get_dir_offset_y(dir)

                        if ax >= 0 && ax < w && ay >= 0 && ay < h {
                            ai := chf.cells[ax + ay * w].index + u32(get_con(s, dir))
                            if ai < u32(len(src_reg)) {
                                rai := src_reg[ai]
                                if rai != RC_NULL_LAYER &&
                                   rai != ri &&
                                   int(rai) < len(regions) {
                                    // Add unique neighbor
                                    add_unique(&reg.neighbors, rai)
                                }
                            }
                        }
                    }
                }
            }

            // Add overlapping layers for all regions in this cell
            for i in 0 ..< len(local_regions) {
                for j in i + 1 ..< len(local_regions) {
                    ri := local_regions[i]
                    rj := local_regions[j]
                    if int(ri) < len(regions) && int(rj) < len(regions) {
                        add_unique(&regions[ri].overlapping_layers, rj)
                        add_unique(&regions[rj].overlapping_layers, ri)
                    }
                }
            }
        }
    }

    return true
}

// Phase 3: Layer assignment via DFS (Odin-idiomatic)
assign_layers_dfs :: proc(regions: []Heightfield_Layer_Region) -> int {
    stack := make([dynamic]int)
    defer delete(stack)

    layer_id: u8 = 0

    for i in 0 ..< len(regions) {
        root := &regions[i]
        if root.layer_id != RC_NULL_LAYER {
            continue
        }

        // Start new layer with this region as root
        root.layer_id = layer_id
        root.is_base = true

        // Start new layer with this region as root

        // Initialize stack with root
        clear(&stack)
        append(&stack, i)

        // Process stack using DFS
        for len(stack) > 0 {
            // Pop from stack
            reg_idx := pop(&stack)
            reg := &regions[reg_idx]

            // Check all neighbors
            for nei_id in reg.neighbors {
                if int(nei_id) >= len(regions) {
                    continue
                }

                nei := &regions[nei_id]
                if nei.layer_id != RC_NULL_LAYER {
                    continue  // Already visited
                }

                // Check if neighbor overlaps with root region
                if slice.contains(root.overlapping_layers[:], u8(nei_id)) {
                    continue  // Skip overlapping regions
                }

                // Check if combined height range would exceed 255
                ymin := min(root.height_bounds.x, nei.height_bounds.x)
                ymax := max(root.height_bounds.y, nei.height_bounds.y)
                if ymax - ymin >= 255 {
                    continue  // Skip if height range too large
                }

                // Add neighbor to same layer
                nei.layer_id = layer_id

                // Add to stack
                append(&stack, int(nei_id))

                // Merge neighbor's overlapping layers into root
                for overlap_id in nei.overlapping_layers {
                    add_unique(&root.overlapping_layers, overlap_id)
                }

                // Update root's height bounds
                root.height_bounds.x = ymin
                root.height_bounds.y = ymax
            }
        }

        layer_id += 1
        if layer_id == RC_NULL_LAYER {
            log.warn("build_heightfield_layers: Layer ID overflow (>255 layers not supported)")
            break
        }
    }

    return int(layer_id)
}

// Phase 4: Height-based layer merging (Odin-idiomatic)
merge_layers :: proc(regions: []Heightfield_Layer_Region, walkable_height: i32) -> int {
    merge_height := u16(walkable_height * 4)
    max_iterations := len(regions) * 2  // Reasonable upper bound
    iteration := 0

    // Start merging process

    // Keep merging until no more merges are possible
    for iteration < max_iterations {
        merged := false
        iteration += 1

        // Find regions to merge
        for i in 0 ..< len(regions) {
            ri := &regions[i]
            if !ri.is_base || ri.layer_id == RC_NULL_LAYER {
                continue  // Skip non-base or unassigned regions
            }

            for j in i + 1 ..< len(regions) {
                rj := &regions[j]
                if !rj.is_base || rj.layer_id == RC_NULL_LAYER {
                    continue  // Skip non-base or unassigned regions
                }

                // Check if layers can be merged
                if ri.layer_id == rj.layer_id {
                    continue  // Already same layer
                }

                // Check if layers can be merged

                // Check height overlap using modernized bounds arrays
                ri_extended := [2]u16{ri.height_bounds.x, ri.height_bounds.y + merge_height}
                rj_extended := [2]u16{rj.height_bounds.x, rj.height_bounds.y + merge_height}
                if !ranges_overlap(ri_extended, rj_extended) {
                    continue  // No height overlap
                }

                // Check if combined height range would exceed 255
                ymin := min(ri.height_bounds.x, rj.height_bounds.x)
                ymax := max(ri.height_bounds.y, rj.height_bounds.y)
                if ymax - ymin >= 255 {
                    continue  // Combined range too large
                }

                // Check for overlapping regions
                // We need to check if any region in layer i overlaps with any region in layer j
                can_merge := true

                // Check if ri overlaps with rj directly
                if slice.contains(ri.overlapping_layers[:], u8(j)) {
                    can_merge = false
                }

                // Also check all regions that have been assigned to these layers
                if can_merge {
                    for k in 0 ..< len(regions) {
                        if regions[k].layer_id == ri.layer_id {
                            for overlap_id in regions[k].overlapping_layers {
                                // Check if this overlapping region belongs to rj's layer
                                if int(overlap_id) < len(regions) && regions[overlap_id].layer_id == rj.layer_id {
                                    can_merge = false
                                    break
                                }
                            }
                            if !can_merge do break
                        }
                    }
                }

                if !can_merge {
                    continue
                }

                // Merge rj into ri

                // Merge rj into ri
                old_id := rj.layer_id
                new_id := ri.layer_id

                // Update all regions with old_id to new_id
                for &reg in regions {
                    if reg.layer_id == old_id {
                        reg.layer_id = new_id
                        reg.is_base = false  // No longer base
                    }
                }

                // Merge overlapping layers
                for overlap_id in rj.overlapping_layers {
                    add_unique(&ri.overlapping_layers, overlap_id)
                }

                // Update combined height bounds
                ri.height_bounds.x = ymin
                ri.height_bounds.y = ymax

                merged = true
                break
            }

            if merged {
                break
            }
        }

        if !merged {
            break  // No more merges possible
        }
    }

    if iteration >= max_iterations {
        log.warnf("Layer merging reached maximum iterations (%d), stopping to prevent infinite loop", max_iterations)
    }

    // Count final number of layers
    layer_count := 0
    for reg in regions {
        if reg.is_base && reg.layer_id != RC_NULL_LAYER {
            layer_count = max(layer_count, int(reg.layer_id) + 1)
        }
    }

    return layer_count
}

// Phase 5: Layer compaction (Odin-idiomatic)
compact_layer_ids :: proc(regions: []Heightfield_Layer_Region) -> int {
    // Find which layer IDs are actually used
    used_layers := make([dynamic]bool, 256)
    defer delete(used_layers)

    slice.fill(used_layers[:], false)

    for reg in regions {
        if reg.layer_id != RC_NULL_LAYER {
            used_layers[reg.layer_id] = true
        }
    }

    // Create sequential remapping
    remap := make([]u8, 256)
    defer delete(remap)

    layer_id: u8 = 0
    for i in 0 ..< len(used_layers) {
        if used_layers[i] {
            remap[i] = layer_id
            layer_id += 1
        } else {
            remap[i] = RC_NULL_LAYER
        }
    }

    // Apply remapping to all regions
    for &reg in regions {
        if reg.layer_id != RC_NULL_LAYER {
            reg.layer_id = remap[reg.layer_id]
        }
    }

    return int(layer_id)
}

// Phase 6: Build a single layer using region assignments (Odin-idiomatic)
build_single_layer :: proc(
    chf: ^Compact_Heightfield,
    src_reg: []u8,
    regions: []Heightfield_Layer_Region,
    layer_id: u8,
    border_size: i32,
    layers: ^[dynamic]Heightfield_Layer,
) -> bool {
    w := chf.width
    h := chf.height

    // All layers have the same full size (minus border)
    // This prevents fragmentation into many small layers
    layer_width := w - border_size * 2
    layer_height := h - border_size * 2

    if layer_width <= 0 || layer_height <= 0 {
        return false
    }

    // Find height bounds for this layer
    hmin := i32(0xffff)
    hmax := i32(0)
    span_count := 0

    // Also track actual data bounds for minx/maxx/miny/maxy
    // (these are stored in the layer but don't affect the layer size)
    data_minx := i32(w)
    data_maxx := i32(0)
    data_miny := i32(h)
    data_maxy := i32(0)

    for y in 0 ..< h {
        for x in 0 ..< w {
            c := &chf.cells[x + y * w]

            for i in c.index ..< c.index + u32(c.count) {
                if i >= u32(len(src_reg)) {
                    continue
                }

                ri := src_reg[i]
                if ri == RC_NULL_LAYER || int(ri) >= len(regions) {
                    continue
                }

                if regions[ri].layer_id != layer_id {
                    continue
                }

                if i >= u32(len(chf.spans)) {
                    continue
                }

                s := &chf.spans[i]

                // Track actual data bounds
                data_minx = min(data_minx, i32(x))
                data_maxx = max(data_maxx, i32(x))
                data_miny = min(data_miny, i32(y))
                data_maxy = max(data_maxy, i32(y))

                // Track height bounds
                hmin = min(hmin, i32(s.y))
                hmax = max(hmax, i32(s.y) + i32(s.h))
                span_count += 1
            }
        }
    }

    if span_count == 0 {
        return false
    }

    // The actual layer origin is offset by border_size
    layer_minx := border_size
    layer_miny := border_size

    // Create layer with full size
    // Adjust bounding box to fit the layer (accounting for border)
    layer_bmin := chf.bmin
    layer_bmax := chf.bmax
    layer_bmin.x += f32(border_size) * chf.cs
    layer_bmin.z += f32(border_size) * chf.cs
    layer_bmax.x -= f32(border_size) * chf.cs
    layer_bmax.z -= f32(border_size) * chf.cs
    layer_bmin.y = chf.bmin.y + f32(hmin) * chf.ch
    layer_bmax.y = chf.bmin.y + f32(hmax) * chf.ch

    layer := Heightfield_Layer {
        bmin = layer_bmin,
        bmax = layer_bmax,
        cs = chf.cs,
        ch = chf.ch,
        width = layer_width,
        height = layer_height,
        minx = data_minx,  // Store actual data bounds for reference
        maxx = data_maxx,
        miny = data_miny,
        maxy = data_maxy,
        hmin = hmin,
        hmax = hmax,
        heights = make([]u8, int(layer_width * layer_height)),
        areas = make([]u8, int(layer_width * layer_height)),
        cons = make([]u8, int(layer_width * layer_height)),
    }

    // Initialize arrays
    slice.fill(layer.heights, 0xff)
    slice.fill(layer.areas, RC_NULL_AREA)
    slice.fill(layer.cons, 0)

    // Fill layer data - scan the full grid
    for y in 0 ..< h {
        for x in 0 ..< w {
            c := &chf.cells[x + y * w]

            for i in c.index ..< c.index + u32(c.count) {
                if i >= u32(len(src_reg)) {
                    continue
                }

                ri := src_reg[i]
                if ri == RC_NULL_LAYER || int(ri) >= len(regions) {
                    continue
                }

                if regions[ri].layer_id != layer_id {
                    continue
                }

                if i >= u32(len(chf.spans)) || i >= u32(len(chf.areas)) {
                    continue
                }

                s := &chf.spans[i]
                // Convert to layer coordinates (offset by border_size)
                lx := x - border_size
                ly := y - border_size

                // Skip if outside layer bounds
                if lx < 0 || lx >= layer_width || ly < 0 || ly >= layer_height {
                    continue
                }

                lidx := lx + ly * layer_width

                if lidx < 0 || lidx >= i32(len(layer.heights)) {
                    continue
                }

                // Store height relative to layer minimum
                relative_height := i32(s.y) - hmin
                layer.heights[lidx] = u8(clamp(int(relative_height), 0, 255))
                layer.areas[lidx] = chf.areas[i]

                // Build connections with portal handling
                cons: u8 = 0
                for dir in 0 ..< 4 {
                    if get_con(s, dir) != RC_NOT_CONNECTED {
                        ax := x + get_dir_offset_x(dir)
                        ay := y + get_dir_offset_y(dir)

                        if ax >= 0 && ax < w && ay >= 0 && ay < h {
                            ac := &chf.cells[ax + ay * w]
                            ai := ac.index + u32(get_con(s, dir))

                            if ai < u32(len(src_reg)) {
                                rai := src_reg[ai]
                                if rai != RC_NULL_LAYER && int(rai) < len(regions) {
                                    // Check if connected span is in same layer
                                    if regions[rai].layer_id == layer_id {
                                        // Connection within same layer
                                        // Check if neighbor is within layer bounds
                                        alx := ax - border_size
                                        aly := ay - border_size
                                        if alx >= 0 && alx < layer_width && aly >= 0 && aly < layer_height {
                                            cons |= u8(1 << u8(dir))
                                        }
                                    } else {
                                        // Portal connection to different layer
                                        alx := ax - border_size
                                        aly := ay - border_size
                                        if alx >= 0 && alx < layer_width && aly >= 0 && aly < layer_height {
                                            cons |= u8(1 << u8(dir))
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                layer.cons[lidx] = cons
            }
        }
    }

    append(layers, layer)
    return true
}

// Get height value from layer at given coordinates
get_layer_height :: proc(layer: ^Heightfield_Layer, x, y: i32) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return 0xff
  }

  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.heights)) {
    return 0xff
  }

  return layer.heights[idx]
}

// Get area ID from layer at given coordinates
get_layer_area :: proc(layer: ^Heightfield_Layer, x, y: i32) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return RC_NULL_AREA
  }

  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.areas)) {
    return RC_NULL_AREA
  }

  return layer.areas[idx]
}

// Get connection info from layer at given coordinates
get_layer_connection :: proc(
  layer: ^Heightfield_Layer,
  x, y: i32,
) -> u8 {
  if x < 0 || x >= layer.width || y < 0 || y >= layer.height {
    return 0
  }

  idx := x + y * layer.width
  if idx < 0 || idx >= i32(len(layer.cons)) {
    return 0
  }

  return layer.cons[idx]
}

// Validate layer set integrity
validate_layer_set :: proc(lset: [dynamic]Heightfield_Layer) -> bool {
  if len(lset) == 0 do return false

  for layer, i in lset {
    // Check bounds
    if layer.width <= 0 || layer.height <= 0 {
      log.errorf(
        "Layer %d has invalid dimensions: %dx%d",
        i,
        layer.width,
        layer.height,
      )
      return false
    }

    expected_size := int(layer.width * layer.height)
    if len(layer.heights) != expected_size ||
       len(layer.areas) != expected_size ||
       len(layer.cons) != expected_size {
      log.errorf("Layer %d has mismatched array sizes", i)
      return false
    }

    // Check coordinate bounds
    if layer.minx > layer.maxx || layer.miny > layer.maxy {
      log.errorf("Layer %d has invalid coordinate bounds", i)
      return false
    }
  }

  return true
}
