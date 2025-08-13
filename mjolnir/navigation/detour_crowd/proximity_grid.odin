package navigation_detour_crowd

import "core:math"
import "core:math/linalg"
import recast "../recast"

// Invalid grid item identifier
DT_INVALID_GRID_ITEM :: u16(0xffff)

// Initialize proximity grid
proximity_grid_init :: proc(grid: ^Proximity_Grid, max_items: i32, cell_size: f32) -> recast.Status {
    if grid == nil || max_items <= 0 || cell_size <= 0 {
        return {.Invalid_Param}
    }

    grid.max_items = max_items
    grid.cell_size = cell_size
    grid.inv_cell_size = 1.0 / cell_size

    // Initialize hash table size to be a power of 2
    grid.hash_size = dt_next_power_of_2(max_items)

    // Allocate memory
    grid.pool = make([dynamic]u16, 0, max_items * 2)  // Each item stores next pointer
    grid.buckets = make([dynamic]u16, grid.hash_size)

    // Initialize buckets to invalid
    for i in 0..<grid.hash_size {
        grid.buckets[i] = DT_INVALID_GRID_ITEM
    }

    // Initialize bounds to invalid state
    grid.bounds = {math.F32_MAX, math.F32_MAX, -math.F32_MAX, -math.F32_MAX}

    return {.Success}
}

// Destroy proximity grid
proximity_grid_destroy :: proc(grid: ^Proximity_Grid) {
    if grid == nil do return

    delete(grid.pool)
    delete(grid.buckets)
    grid.pool = nil
    grid.buckets = nil
    grid.max_items = 0
    grid.hash_size = 0
}

// Clear all items from grid
proximity_grid_clear :: proc(grid: ^Proximity_Grid) {
    if grid == nil do return

    clear(&grid.pool)

    // Reset all buckets to invalid
    for i in 0..<grid.hash_size {
        grid.buckets[i] = DT_INVALID_GRID_ITEM
    }

    // Reset bounds
    grid.bounds = {math.F32_MAX, math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
}

// Add item to grid at given position
proximity_grid_add_item :: proc(grid: ^Proximity_Grid, item_id: u16, min_x, min_z, max_x, max_z: f32) -> recast.Status {
    if grid == nil {
        return {.Invalid_Param}
    }

    if len(grid.pool) + 4 >= grid.max_items * 2 {
        return {.Out_Of_Memory}
    }

    // Update bounds
    grid.bounds[0] = min(grid.bounds[0], min_x)
    grid.bounds[1] = min(grid.bounds[1], min_z)
    grid.bounds[2] = max(grid.bounds[2], max_x)
    grid.bounds[3] = max(grid.bounds[3], max_z)

    // Calculate grid coordinates
    min_grid := linalg.floor([2]f32{min_x, min_z} * grid.inv_cell_size)
    max_grid := linalg.floor([2]f32{max_x, max_z} * grid.inv_cell_size)

    // Add to all cells that the item overlaps
    for gz in i32(min_grid.y)..=i32(max_grid.y) {
        for gx in i32(min_grid.x)..=i32(max_grid.x) {
            hash := hash_pos(gx, gz, grid.hash_size)

            // Add item to this cell's linked list
            pool_idx := u16(len(grid.pool))
            append(&grid.pool, item_id)           // Item ID
            append(&grid.pool, grid.buckets[hash]) // Next pointer
            grid.buckets[hash] = pool_idx
        }
    }

    return {.Success}
}

// Query items in circular area
proximity_grid_query_items :: proc(grid: ^Proximity_Grid, center_x, center_z, radius: f32,
                                     ids: []u16, max_ids: i32) -> i32 {
    if grid == nil || max_ids <= 0 {
        return 0
    }

    radius_sqr := radius * radius
    count := i32(0)

    // Calculate grid bounds for the query circle
    min_grid := linalg.floor([2]f32{center_x - radius, center_z - radius} * grid.inv_cell_size)
    max_grid := linalg.floor([2]f32{center_x + radius, center_z + radius} * grid.inv_cell_size)

    // Visit all cells in the query area
    for gz in i32(min_grid.y)..=i32(max_grid.y) {
        for gx in i32(min_grid.x)..=i32(max_grid.x) {
            hash := hash_pos(gx, gz, grid.hash_size)

            // Walk through linked list for this cell
            item_idx := grid.buckets[hash]
            for item_idx != DT_INVALID_GRID_ITEM && count < max_ids {
                if int(item_idx) + 1 >= len(grid.pool) do break

                item_id := grid.pool[item_idx]
                next_idx := grid.pool[item_idx + 1]

                // Check if item is already in results (avoid duplicates)
                duplicate := false
                for i in 0..<count {
                    if ids[i] == item_id {
                        duplicate = true
                        break
                    }
                }

                if !duplicate {
                    ids[count] = item_id
                    count += 1
                }

                item_idx = next_idx
            }
        }
    }

    return count
}

// Query items near a point
proximity_grid_query_items_at :: proc(grid: ^Proximity_Grid, x, z: f32, ids: []u16, max_ids: i32) -> i32 {
    if grid == nil || max_ids <= 0 {
        return 0
    }

    count := i32(0)

    // Calculate grid coordinates  
    grid_pos := linalg.floor([2]f32{x, z} * grid.inv_cell_size)
    hash := hash_pos(i32(grid_pos.x), i32(grid_pos.y), grid.hash_size)

    // Walk through linked list for this cell
    item_idx := grid.buckets[hash]
    for item_idx != DT_INVALID_GRID_ITEM && count < max_ids {
        if int(item_idx) + 1 >= len(grid.pool) do break

        item_id := grid.pool[item_idx]
        next_idx := grid.pool[item_idx + 1]

        ids[count] = item_id
        count += 1

        item_idx = next_idx
    }

    return count
}

// Get items in rectangular area
proximity_grid_query_items_in_rect :: proc(grid: ^Proximity_Grid, min_x, min_z, max_x, max_z: f32,
                                              ids: []u16, max_ids: i32) -> i32 {
    if grid == nil || max_ids <= 0 {
        return 0
    }

    count := i32(0)

    // Calculate grid bounds
    min_grid := linalg.floor([2]f32{min_x, min_z} * grid.inv_cell_size)
    max_grid := linalg.floor([2]f32{max_x, max_z} * grid.inv_cell_size)

    // Visit all cells in the rectangle
    for gz in i32(min_grid.y)..=i32(max_grid.y) {
        for gx in i32(min_grid.x)..=i32(max_grid.x) {
            hash := hash_pos(gx, gz, grid.hash_size)

            // Walk through linked list for this cell
            item_idx := grid.buckets[hash]
            for item_idx != DT_INVALID_GRID_ITEM && count < max_ids {
                if int(item_idx) + 1 >= len(grid.pool) do break

                item_id := grid.pool[item_idx]
                next_idx := grid.pool[item_idx + 1]

                // Check for duplicates
                duplicate := false
                for i in 0..<count {
                    if ids[i] == item_id {
                        duplicate = true
                        break
                    }
                }

                if !duplicate {
                    ids[count] = item_id
                    count += 1
                }

                item_idx = next_idx
            }
        }
    }

    return count
}

// Get grid bounds
proximity_grid_get_bounds :: proc(grid: ^Proximity_Grid) -> [4]f32 {
    if grid == nil {
        return {}
    }
    return grid.bounds
}

// Get cell size
proximity_grid_get_cell_size :: proc(grid: ^Proximity_Grid) -> f32 {
    if grid == nil do return 0
    return grid.cell_size
}

// Get item count (approximate, includes duplicates)
proximity_grid_get_item_count :: proc(grid: ^Proximity_Grid) -> i32 {
    if grid == nil do return 0
    return i32(len(grid.pool)) / 2  // Each item uses 2 pool slots
}

// Hash function for grid coordinates
hash_pos :: proc(x, z, hash_size: i32) -> i32 {
    // Simple hash function using prime numbers
    h1 := u32(x) * 0x8da6b343
    h2 := u32(z) * 0xd8163841
    h := (h1 + h2) & 0xffffffff
    return i32(h) & (hash_size - 1)
}

// Find next power of 2
dt_next_power_of_2 :: proc(v: i32) -> i32 {
    result := i32(1)
    for result < v {
        result <<= 1
    }
    return result
}

// Check if grid is empty
proximity_grid_is_empty :: proc(grid: ^Proximity_Grid) -> bool {
    if grid == nil do return true
    return len(grid.pool) == 0
}

// Get memory usage statistics
proximity_grid_get_memory_usage :: proc(grid: ^Proximity_Grid) -> (items_memory: i32, buckets_memory: i32, total_memory: i32) {
    if grid == nil do return 0, 0, 0

    items_memory = i32(len(grid.pool)) * size_of(u16)
    buckets_memory = i32(len(grid.buckets)) * size_of(u16)
    total_memory = items_memory + buckets_memory

    return
}

// Reset bounds (for optimization before adding many items)
proximity_grid_reset_bounds :: proc(grid: ^Proximity_Grid) {
    if grid == nil do return
    grid.bounds = {math.F32_MAX, math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
}

// Check if point is within grid bounds
proximity_grid_contains_point :: proc(grid: ^Proximity_Grid, x, z: f32) -> bool {
    if grid == nil do return false

    return x >= grid.bounds[0] && z >= grid.bounds[1] &&
           x <= grid.bounds[2] && z <= grid.bounds[3]
}
