package navigation_detour_crowd

import "core:fmt"
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

    // Initialize hash table size to be a larger power of 2 to reduce collisions
    // Use at least 4x the max items to reduce collision probability
    grid.hash_size = dt_next_power_of_2(max_items * 4)

    // Allocate memory
    // Each item can span multiple cells, estimate 8 cells per item on average
    grid.pool = make([dynamic]u16, 0, max_items * 16)  // Pool needs more space for multi-cell items
    grid.buckets = make([dynamic]u16, grid.hash_size)
    grid.item_bounds = make([dynamic][4]f32, 0, max_items)
    grid.item_ids = make([dynamic]u16, 0, max_items)

    // Initialize buckets to invalid
    for i in 0..<grid.hash_size {
        grid.buckets[i] = DT_INVALID_GRID_ITEM
    }

    // Initialize bounds to invalid state
    grid.bounds = {math.F32_MAX, math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
    
    // Initialize item count
    grid.item_count = 0

    return {.Success}
}

// Destroy proximity grid
proximity_grid_destroy :: proc(grid: ^Proximity_Grid) {
    if grid == nil do return

    delete(grid.pool)
    delete(grid.buckets)
    delete(grid.item_bounds)
    delete(grid.item_ids)
    grid.pool = nil
    grid.buckets = nil
    grid.max_items = 0
    grid.hash_size = 0
}

// Clear all items from grid
proximity_grid_clear :: proc(grid: ^Proximity_Grid) {
    if grid == nil do return

    clear(&grid.pool)
    clear(&grid.item_bounds)
    clear(&grid.item_ids)

    // Reset all buckets to invalid
    for i in 0..<grid.hash_size {
        grid.buckets[i] = DT_INVALID_GRID_ITEM
    }

    // Reset bounds
    grid.bounds = {math.F32_MAX, math.F32_MAX, -math.F32_MAX, -math.F32_MAX}
    
    // Reset item count
    grid.item_count = 0
}

// Add item to grid at given position
proximity_grid_add_item :: proc(grid: ^Proximity_Grid, item_id: u16, min_x, min_z, max_x, max_z: f32) -> recast.Status {
    if grid == nil {
        return {.Invalid_Param}
    }

    // Check if we've reached the maximum number of unique items
    if grid.item_count >= grid.max_items {
        return {.Out_Of_Memory}
    }
    
    // Store item bounds and ID
    append(&grid.item_bounds, [4]f32{min_x, min_z, max_x, max_z})
    append(&grid.item_ids, item_id)
    
    // Increment unique item count
    grid.item_count += 1

    // Update bounds
    grid.bounds[0] = min(grid.bounds[0], min_x)
    grid.bounds[1] = min(grid.bounds[1], min_z)
    grid.bounds[2] = max(grid.bounds[2], max_x)
    grid.bounds[3] = max(grid.bounds[3], max_z)

    // Calculate grid coordinates  
    min_grid := linalg.floor([2]f32{min_x, min_z} * grid.inv_cell_size)
    // Subtract epsilon to avoid including boundary cells
    max_grid := linalg.floor([2]f32{max_x - 0.0001, max_z - 0.0001} * grid.inv_cell_size)

    // Add to all cells that the item overlaps
    for gz in i32(min_grid.y)..=i32(max_grid.y) {
        for gx in i32(min_grid.x)..=i32(max_grid.x) {
            // Check if we have space in the pool for this entry
            if i32(len(grid.pool)) + 2 > grid.max_items * 16 {
                // Pool is full, but we already incremented item count, so decrement it
                grid.item_count -= 1
                return {.Out_Of_Memory}
            }
            
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
                    // Find the item bounds to check distance
                    item_found := false
                    for j in 0..<len(grid.item_ids) {
                        if grid.item_ids[j] == item_id {
                            item_bnd := grid.item_bounds[j]
                            
                            // Check if item bounding box overlaps with query circle
                            // Find closest point on bounding box to circle center
                            closest_x := max(item_bnd[0], min(center_x, item_bnd[2]))
                            closest_z := max(item_bnd[1], min(center_z, item_bnd[3]))
                            
                            // Check distance from closest point to center
                            dx := closest_x - center_x
                            dz := closest_z - center_z
                            dist_sqr := dx * dx + dz * dz
                            
                            if dist_sqr <= radius_sqr {
                                ids[count] = item_id
                                count += 1
                                item_found = true
                            }
                            break
                        }
                    }
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

        // Check if item is already in results (avoid duplicates)
        duplicate := false
        for i in 0..<count {
            if ids[i] == item_id {
                duplicate = true
                break
            }
        }

        if !duplicate {
            // Find the item bounds to check if point is within bounds
            for j in 0..<len(grid.item_ids) {
                if grid.item_ids[j] == item_id {
                    item_bnd := grid.item_bounds[j]
                    
                    // Check if point is within item bounds
                    if x >= item_bnd[0] && x <= item_bnd[2] &&
                       z >= item_bnd[1] && z <= item_bnd[3] {
                        ids[count] = item_id
                        count += 1
                    }
                    break
                }
            }
        }

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
            
            // Debug output - enable temporarily
            //fmt.printf("Checking cell (%d,%d), hash=%d\n", gx, gz, hash)

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
                    // Find the item bounds to check if it intersects query rectangle
                    for j in 0..<len(grid.item_ids) {
                        if grid.item_ids[j] == item_id {
                            item_bnd := grid.item_bounds[j]
                            
                            // Check if item bounding box intersects with query rectangle
                            // For proper intersection: right edge > left edge AND top edge > bottom edge
                            if item_bnd[2] > min_x && item_bnd[0] < max_x &&
                               item_bnd[3] > min_z && item_bnd[1] < max_z {
                                ids[count] = item_id
                                count += 1
                            }
                            break
                        }
                    }
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

// Get item count (unique items)
proximity_grid_get_item_count :: proc(grid: ^Proximity_Grid) -> i32 {
    if grid == nil do return 0
    return grid.item_count
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
