package test_detour_crowd

import "core:testing"
import "core:time"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import "core:slice"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

// =============================================================================
// Proximity Grid Unit Tests
// =============================================================================

@(test)
test_proximity_grid_initialization_exact_values :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    grid := new(crowd.Proximity_Grid)
    defer free(grid)
    
    // Initialize with specific parameters
    max_items := i32(50)
    cell_size := f32(2.5)
    
    status := crowd.proximity_grid_init(grid, max_items, cell_size)
    testing.expect(t, recast.status_succeeded(status), "Failed to initialize proximity grid")
    defer crowd.proximity_grid_destroy(grid)
    
    // Verify exact initialization values
    testing.expect(t, grid.max_items == max_items, "Max items should be exactly 50")
    testing.expect(t, grid.cell_size == cell_size, "Cell size should be exactly 2.5")
    testing.expect(t, grid.inv_cell_size == 1.0/cell_size, "Inverse cell size should be 1/2.5 = 0.4")
    testing.expect(t, len(grid.pool) == 0, "Pool should start empty")
    testing.expect(t, len(grid.buckets) > 0, "Buckets should be allocated")
    testing.expect(t, grid.hash_size > 0, "Hash size should be positive")
    
    // Verify grid starts empty
    testing.expect(t, crowd.proximity_grid_is_empty(grid), "Grid should start empty")
    testing.expect(t, crowd.proximity_grid_get_item_count(grid) == 0, "Item count should be 0")
    
    // Verify bounds are initialized
    bounds := crowd.proximity_grid_get_bounds(grid)
    testing.expect(t, bounds[0] == math.F32_MAX, "Min X should be F32_MAX initially")
    testing.expect(t, bounds[1] == math.F32_MAX, "Min Z should be F32_MAX initially")
    testing.expect(t, bounds[2] == -math.F32_MAX, "Max X should be -F32_MAX initially")
    testing.expect(t, bounds[3] == -math.F32_MAX, "Max Z should be -F32_MAX initially")
}

@(test)
test_proximity_grid_add_item_exact_positions :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    grid := new(crowd.Proximity_Grid)
    defer free(grid)
    
    crowd.proximity_grid_init(grid, 20, 1.0)
    defer crowd.proximity_grid_destroy(grid)
    
    // Add items at specific positions
    test_items := []struct {
        id: u16,
        min_x, min_z, max_x, max_z: f32,
    }{
        {1, 0.0, 0.0, 1.0, 1.0},     // Unit square at origin
        {2, 5.0, 5.0, 6.0, 6.0},     // Unit square at (5,5)
        {3, -2.0, -2.0, -1.0, -1.0}, // Unit square at (-2,-2)
        {4, 10.0, 0.0, 11.0, 1.0},   // Rectangle
        {5, 0.0, 10.0, 1.0, 11.0},   // Rectangle
    }
    
    // Add all test items
    for item in test_items {
        status := crowd.proximity_grid_add_item(grid, item.id, item.min_x, item.min_z, item.max_x, item.max_z)
        testing.expect(t, recast.status_succeeded(status), "Should add item successfully")
    }
    
    // Verify exact item count
    testing.expect(t, crowd.proximity_grid_get_item_count(grid) == i32(len(test_items)), 
                  fmt.tprintf("Should have exactly %d items", len(test_items)))
    testing.expect(t, !crowd.proximity_grid_is_empty(grid), "Grid should not be empty")
    
    // Verify bounds were updated correctly
    bounds := crowd.proximity_grid_get_bounds(grid)
    expected_min_x := f32(-2.0)  // From item 3
    expected_min_z := f32(-2.0)  // From item 3
    expected_max_x := f32(11.0)  // From item 4
    expected_max_z := f32(11.0)  // From item 5
    
    testing.expect(t, bounds[0] == expected_min_x, "Min X should be -2.0")
    testing.expect(t, bounds[1] == expected_min_z, "Min Z should be -2.0")
    testing.expect(t, bounds[2] == expected_max_x, "Max X should be 11.0")
    testing.expect(t, bounds[3] == expected_max_z, "Max Z should be 11.0")
    
    fmt.printf("Grid bounds: [%.1f, %.1f, %.1f, %.1f]\n", bounds[0], bounds[1], bounds[2], bounds[3])
}

@(test)
test_proximity_grid_query_exact_results :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    grid := new(crowd.Proximity_Grid)
    defer free(grid)
    
    crowd.proximity_grid_init(grid, 15, 2.0)
    defer crowd.proximity_grid_destroy(grid)
    
    // Add items in a known pattern
    // Group A: Items around (0,0)
    crowd.proximity_grid_add_item(grid, 10, -1.0, -1.0, 1.0, 1.0)   // Center
    crowd.proximity_grid_add_item(grid, 11, 1.5, -1.0, 2.5, 1.0)    // East
    crowd.proximity_grid_add_item(grid, 12, -1.0, 1.5, 1.0, 2.5)    // North
    
    // Group B: Items around (10,10) - should be separate
    crowd.proximity_grid_add_item(grid, 20, 9.0, 9.0, 11.0, 11.0)   // Far center
    crowd.proximity_grid_add_item(grid, 21, 11.5, 9.0, 12.5, 11.0)  // Far east
    
    // Single isolated item
    crowd.proximity_grid_add_item(grid, 30, -10.0, -10.0, -9.0, -9.0)
    
    // Test query at origin - should find Group A items
    result_ids := make([]u16, 10)
    defer delete(result_ids)
    
    count_origin := crowd.proximity_grid_query_items(grid, 0.0, 0.0, 3.0, result_ids[:], 10)
    testing.expect(t, count_origin == 3, "Should find exactly 3 items near origin")
    
    // Verify specific items found
    origin_items := result_ids[:count_origin]
    slice.sort(origin_items)  // Sort for predictable order
    expected_origin := []u16{10, 11, 12}
    testing.expect(t, slice.equal(origin_items, expected_origin), "Should find items 10, 11, 12 near origin")
    
    // Test query at (10,10) - should find Group B items
    count_far := crowd.proximity_grid_query_items(grid, 10.0, 10.0, 3.0, result_ids[:], 10)
    testing.expect(t, count_far == 2, "Should find exactly 2 items near (10,10)")
    
    far_items := result_ids[:count_far]
    slice.sort(far_items)
    expected_far := []u16{20, 21}
    testing.expect(t, slice.equal(far_items, expected_far), "Should find items 20, 21 near (10,10)")
    
    // Test query at isolated item location
    count_isolated := crowd.proximity_grid_query_items(grid, -9.5, -9.5, 2.0, result_ids[:], 10)
    testing.expect(t, count_isolated == 1, "Should find exactly 1 isolated item")
    testing.expect(t, result_ids[0] == 30, "Should find item 30 in isolated location")
    
    // Test empty region query
    count_empty := crowd.proximity_grid_query_items(grid, 100.0, 100.0, 5.0, result_ids[:], 10)
    testing.expect(t, count_empty == 0, "Should find no items in empty region")
    
    fmt.printf("Query results: origin=%d, far=%d, isolated=%d, empty=%d\n",
              count_origin, count_far, count_isolated, count_empty)
}

@(test)
test_proximity_grid_query_at_exact_coordinates :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    grid := new(crowd.Proximity_Grid)
    defer free(grid)
    
    crowd.proximity_grid_init(grid, 8, 1.0)  // 1x1 cells
    defer crowd.proximity_grid_destroy(grid)
    
    // Add items in specific cells
    crowd.proximity_grid_add_item(grid, 1, 0.0, 0.0, 1.0, 1.0)     // Cell (0,0)
    crowd.proximity_grid_add_item(grid, 2, 1.0, 0.0, 2.0, 1.0)     // Cell (1,0)  
    crowd.proximity_grid_add_item(grid, 3, 0.0, 1.0, 1.0, 2.0)     // Cell (0,1)
    crowd.proximity_grid_add_item(grid, 4, 1.0, 1.0, 2.0, 2.0)     // Cell (1,1)
    
    result_ids := make([]u16, 5)
    defer delete(result_ids)
    
    // Query at specific cell centers
    count_00 := crowd.proximity_grid_query_items_at(grid, 0.5, 0.5, result_ids[:], 5)
    testing.expect(t, count_00 == 1, "Should find 1 item at cell (0,0)")
    testing.expect(t, result_ids[0] == 1, "Should find item 1 at (0.5,0.5)")
    
    count_10 := crowd.proximity_grid_query_items_at(grid, 1.5, 0.5, result_ids[:], 5)
    testing.expect(t, count_10 == 1, "Should find 1 item at cell (1,0)")
    testing.expect(t, result_ids[0] == 2, "Should find item 2 at (1.5,0.5)")
    
    count_01 := crowd.proximity_grid_query_items_at(grid, 0.5, 1.5, result_ids[:], 5)
    testing.expect(t, count_01 == 1, "Should find 1 item at cell (0,1)")
    testing.expect(t, result_ids[0] == 3, "Should find item 3 at (0.5,1.5)")
    
    count_11 := crowd.proximity_grid_query_items_at(grid, 1.5, 1.5, result_ids[:], 5)
    testing.expect(t, count_11 == 1, "Should find 1 item at cell (1,1)")
    testing.expect(t, result_ids[0] == 4, "Should find item 4 at (1.5,1.5)")
    
    // Query at cell boundary
    count_boundary := crowd.proximity_grid_query_items_at(grid, 1.0, 1.0, result_ids[:], 5)
    testing.expect(t, count_boundary >= 1, "Should find items at cell boundary")
    
    // Query outside grid bounds
    count_outside := crowd.proximity_grid_query_items_at(grid, -5.0, -5.0, result_ids[:], 5)
    testing.expect(t, count_outside == 0, "Should find no items outside bounds")
}

@(test)
test_proximity_grid_rectangular_query :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    grid := new(crowd.Proximity_Grid)
    defer free(grid)
    
    crowd.proximity_grid_init(grid, 12, 1.0)
    defer crowd.proximity_grid_destroy(grid)
    
    // Create a 3x3 grid of items
    item_id := u16(1)
    for x in 0..<3 {
        for z in 0..<3 {
            min_x := f32(x)
            min_z := f32(z)
            max_x := f32(x + 1)
            max_z := f32(z + 1)
            
            crowd.proximity_grid_add_item(grid, item_id, min_x, min_z, max_x, max_z)
            item_id += 1
        }
    }
    
    result_ids := make([]u16, 15)
    defer delete(result_ids)
    
    // Query specific rectangular regions
    
    // Query top-left 2x2 region
    count_tl := crowd.proximity_grid_query_items_in_rect(grid, 0.0, 0.0, 2.0, 2.0, result_ids[:], 15)
    testing.expect(t, count_tl == 4, "Should find 4 items in top-left 2x2")
    
    tl_items := result_ids[:count_tl]
    slice.sort(tl_items)
    expected_tl := []u16{1, 2, 4, 5}  // Items at (0,0), (1,0), (0,1), (1,1)
    testing.expect(t, slice.equal(tl_items, expected_tl), "Should find correct items in top-left")
    
    // Query center 1x1 region
    count_center := crowd.proximity_grid_query_items_in_rect(grid, 1.0, 1.0, 2.0, 2.0, result_ids[:], 15)
    testing.expect(t, count_center == 1, "Should find 1 item in center")
    testing.expect(t, result_ids[0] == 5, "Should find item 5 at center")
    
    // Query entire 3x3 region
    count_all := crowd.proximity_grid_query_items_in_rect(grid, 0.0, 0.0, 3.0, 3.0, result_ids[:], 15)
    testing.expect(t, count_all == 9, "Should find all 9 items in full region")
    
    all_items := result_ids[:count_all]
    slice.sort(all_items)
    expected_all := []u16{1, 2, 3, 4, 5, 6, 7, 8, 9}
    testing.expect(t, slice.equal(all_items, expected_all), "Should find all items 1-9")
    
    // Query overlapping region - this query intersects all 9 items
    count_overlap := crowd.proximity_grid_query_items_in_rect(grid, 0.5, 0.5, 2.5, 2.5, result_ids[:], 15)
    testing.expect(t, count_overlap == 9, "Should find all 9 items that intersect with overlapping region")
    
    fmt.printf("Rectangle query results: tl=%d, center=%d, all=%d, overlap=%d\n",
              count_tl, count_center, count_all, count_overlap)
    fmt.printf("TL items: %v\n", tl_items)
    fmt.printf("All items: %v\n", all_items)
    fmt.printf("Overlap items: %v\n", result_ids[:count_overlap])
}

@(test)
test_proximity_grid_memory_usage :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    grid := new(crowd.Proximity_Grid)
    defer free(grid)
    
    crowd.proximity_grid_init(grid, 25, 1.5)
    defer crowd.proximity_grid_destroy(grid)
    
    // Check initial memory usage
    items_mem, buckets_mem, total_mem := crowd.proximity_grid_get_memory_usage(grid)
    testing.expect(t, items_mem == 0, "Initial items memory should be 0")
    testing.expect(t, buckets_mem > 0, "Buckets memory should be positive")
    testing.expect(t, total_mem == items_mem + buckets_mem, "Total should equal sum")
    
    fmt.printf("Initial memory: items=%d, buckets=%d, total=%d\n", items_mem, buckets_mem, total_mem)
    
    // Add items and check memory growth
    for i in 1..=10 {
        crowd.proximity_grid_add_item(grid, u16(i), f32(i), f32(i), f32(i+1), f32(i+1))
        
        new_items_mem, new_buckets_mem, new_total_mem := crowd.proximity_grid_get_memory_usage(grid)
        testing.expect(t, new_items_mem >= items_mem, "Items memory should not decrease")
        testing.expect(t, new_total_mem > total_mem, "Total memory should increase")
        
        items_mem = new_items_mem
        total_mem = new_total_mem
    }
    
    fmt.printf("Final memory: items=%d, buckets=%d, total=%d\n", items_mem, buckets_mem, total_mem)
    
    // Clear grid and check memory reduction
    crowd.proximity_grid_clear(grid)
    
    cleared_items_mem, cleared_buckets_mem, cleared_total_mem := crowd.proximity_grid_get_memory_usage(grid)
    testing.expect(t, cleared_items_mem == 0, "Items memory should be 0 after clear")
    testing.expect(t, cleared_buckets_mem == buckets_mem, "Buckets memory should remain same")
    testing.expect(t, cleared_total_mem < total_mem, "Total memory should decrease after clear")
}

// =============================================================================
// Agent Neighbor Detection Unit Tests  
// =============================================================================

@(test)
test_agent_neighbor_detection_spatial_partitioning :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 12)
    defer destroy_test_crowd(crowd_system)
    
    // Create agents in specific spatial pattern
    agent_configs := []struct {
        pos: [3]f32,
        expected_neighbors: []i32,  // Expected neighbor agent indices
    }{
        // Center cluster
        {{15.0, 0.0, 15.0}, {1, 2}},        // Agent 0: should see agents 1,2 (but not 3 due to range)
        {{16.0, 0.0, 15.0}, {0, 3}},        // Agent 1: should see agents 0,3
        {{15.0, 0.0, 16.0}, {0, 3}},        // Agent 2: should see agents 0,3
        {{16.0, 0.0, 16.0}, {1, 2}},        // Agent 3: should see agents 1,2 (but not 0 due to range)
        
        // Distant agents - should not be neighbors of center cluster
        {{25.0, 0.0, 25.0}, {5}},           // Agent 4: should see agent 5
        {{26.0, 0.0, 25.0}, {4}},           // Agent 5: should see agent 4
        
        // Isolated agent - should have no neighbors
        {{5.0, 0.0, 5.0}, {}},              // Agent 6: isolated
    }
    
    agents := make([]recast.Agent_Id, len(agent_configs))
    defer delete(agents)
    
    // Create all agents
    for config, i in agent_configs {
        params := crowd.agent_params_create_default()
        params.collision_query_range = 1.5  // Limited range - should see immediate neighbors
        
        agent_id, status := crowd.crowd_add_agent(crowd_system, config.pos, &params)
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add agent %d", i))
        agents[i] = agent_id
    }
    
    // Update to establish neighbor relationships
    crowd.crowd_update(crowd_system, 0.1, nil)
    
    // Verify neighbor detection for each agent
    for config, i in agent_configs {
        agent := crowd.crowd_get_agent(crowd_system, agents[i])
        testing.expect(t, agent != nil, fmt.tprintf("Agent %d should exist", i))
        
        neighbor_count := crowd.agent_get_neighbor_count(agent)
        expected_count := i32(len(config.expected_neighbors))
        
        testing.expect(t, neighbor_count == expected_count, 
                      fmt.tprintf("Agent %d should have %d neighbors, got %d", i, expected_count, neighbor_count))
        
        // Verify specific neighbor indices and distances
        found_neighbors := make([]i32, neighbor_count)
        for j in 0..<neighbor_count {
            neighbor, found := crowd.agent_get_neighbor(agent, j)
            testing.expect(t, found, fmt.tprintf("Should find neighbor %d for agent %d", j, i))
            
            if found {
                testing.expect(t, neighbor.agent_index >= 0, "Neighbor index should be valid")
                testing.expect(t, neighbor.distance > 0.0, "Neighbor distance should be positive")
                
                found_neighbors[j] = neighbor.agent_index
                
                // Verify distance is reasonable
                neighbor_agent := crowd.crowd_get_agent(crowd_system, agents[neighbor.agent_index])
                if neighbor_agent != nil {
                    actual_distance := linalg.distance(agent.position, neighbor_agent.position)
                    testing.expect(t, math.abs(neighbor.distance - actual_distance) < 0.1,
                                  "Neighbor distance should match actual distance")
                }
            }
        }
        
        // Sort and compare with expected
        slice.sort(found_neighbors)
        slice.sort(config.expected_neighbors)
        
        if !slice.equal(found_neighbors, config.expected_neighbors) {
            fmt.printf("Agent %d neighbor mismatch: found=%v, expected=%v\n",
                      i, found_neighbors, config.expected_neighbors)
            testing.expect(t, false, fmt.tprintf("Agent %d should have correct neighbors", i))
        }
        
        fmt.printf("Agent %d at (%.1f,%.1f): %d neighbors %v\n",
                  i, agent.position.x, agent.position.z, neighbor_count, found_neighbors)
    }
}

@(test)
test_neighbor_distance_accuracy :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 8)
    defer destroy_test_crowd(crowd_system)
    
    // Create agents at known exact distances
    center_pos := [3]f32{10.0, 0.0, 10.0}
    test_positions := []struct {
        pos: [3]f32,
        expected_distance: f32,
    }{
        {{11.0, 0.0, 10.0}, 1.0},         // 1 unit east
        {{12.0, 0.0, 10.0}, 2.0},         // 2 units east  
        {{10.0, 0.0, 13.0}, 3.0},         // 3 units north
        {{13.0, 0.0, 14.0}, 5.0},         // 5 units diagonal (3,4,5 triangle)
        {{10.0, 0.0, 6.0}, 4.0},          // 4 units south
    }
    
    // Add center agent
    center_agent_id := add_test_agent(t, crowd_system, center_pos)
    
    // Add test agents  
    test_agent_ids := make([]recast.Agent_Id, len(test_positions))
    defer delete(test_agent_ids)
    
    for pos_data, i in test_positions {
        test_agent_ids[i] = add_test_agent(t, crowd_system, pos_data.pos)
    }
    
    // Update to establish neighbors
    crowd.crowd_update(crowd_system, 0.1, nil)
    
    // Check center agent's neighbor distances
    center_agent := crowd.crowd_get_agent(crowd_system, center_agent_id)
    testing.expect(t, center_agent != nil, "Center agent should exist")
    
    neighbor_count := crowd.agent_get_neighbor_count(center_agent)
    testing.expect(t, neighbor_count > 0, "Center agent should have neighbors")
    
    // Create map of neighbor distances by agent index
    neighbor_distances := make(map[i32]f32)
    defer delete(neighbor_distances)
    
    for i in 0..<neighbor_count {
        neighbor, found := crowd.agent_get_neighbor(center_agent, i)
        if found {
            neighbor_distances[neighbor.agent_index] = neighbor.distance
        }
    }
    
    // Verify each test agent's distance
    for pos_data, i in test_positions {
        test_agent_index := i32(i + 1)  // Agent indices start from 0 (center), then 1,2,3...
        
        if distance, exists := neighbor_distances[test_agent_index]; exists {
            testing.expect(t, math.abs(distance - pos_data.expected_distance) < 0.3,
                          fmt.tprintf("Agent %d distance should be %.1f, got %.3f", 
                                    i, pos_data.expected_distance, distance))
        } else {
            // Check if agent is within collision query range
            actual_distance := linalg.distance(center_pos, pos_data.pos)
            query_range := center_agent.params.collision_query_range
            
            if actual_distance <= query_range {
                testing.expect(t, false, fmt.tprintf("Agent %d should be detected as neighbor (distance %.1f <= range %.1f)",
                                            i, actual_distance, query_range))
            }
        }
    }
    
    fmt.printf("Center agent neighbor distances: %v\n", neighbor_distances)
}

// =============================================================================
// Spatial Query Integration Tests
// =============================================================================

@(test)  
test_crowd_proximity_grid_integration :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 15)
    defer destroy_test_crowd(crowd_system)
    
    // Verify crowd has proximity grid
    testing.expect(t, crowd_system.proximity_grid != nil, "Crowd should have proximity grid")
    
    // Add agents in specific spatial arrangement
    cluster1_center := [3]f32{10.0, 0.0, 10.0}
    cluster2_center := [3]f32{20.0, 0.0, 20.0}
    
    cluster1_agents := make([]recast.Agent_Id, 4)
    cluster2_agents := make([]recast.Agent_Id, 4)
    defer delete(cluster1_agents)
    defer delete(cluster2_agents)
    
    // Create cluster 1
    cluster1_positions := [][3]f32{
        {10.0, 0.0, 10.0},
        {11.0, 0.0, 10.0},
        {10.0, 0.0, 11.0},
        {11.0, 0.0, 11.0},
    }
    
    for pos, i in cluster1_positions {
        cluster1_agents[i] = add_test_agent(t, crowd_system, pos)
    }
    
    // Create cluster 2 
    cluster2_positions := [][3]f32{
        {20.0, 0.0, 20.0},
        {21.0, 0.0, 20.0}, 
        {20.0, 0.0, 21.0},
        {21.0, 0.0, 21.0},
    }
    
    for pos, i in cluster2_positions {
        cluster2_agents[i] = add_test_agent(t, crowd_system, pos)
    }
    
    // Update crowd to populate proximity grid
    crowd.crowd_update(crowd_system, 0.1, nil)
    
    // Verify proximity grid contains agents
    testing.expect(t, !crowd.proximity_grid_is_empty(crowd_system.proximity_grid), 
                  "Proximity grid should not be empty")
    
    item_count := crowd.proximity_grid_get_item_count(crowd_system.proximity_grid)
    testing.expect(t, item_count == 8, "Proximity grid should contain 8 agents")
    
    // Test neighbor detection within clusters
    for i in 0..<len(cluster1_agents) {
        agent := crowd.crowd_get_agent(crowd_system, cluster1_agents[i])
        if agent == nil do continue
        
        neighbor_count := crowd.agent_get_neighbor_count(agent)
        
        // Each agent in cluster 1 should detect other cluster 1 agents as neighbors
        // but not cluster 2 agents (due to distance)
        testing.expect(t, neighbor_count > 0, "Cluster 1 agent should have neighbors")
        testing.expect(t, neighbor_count <= 3, "Cluster 1 agent should not see more than 3 other cluster agents")
        
        // Verify no cross-cluster neighbors
        for j in 0..<neighbor_count {
            neighbor, found := crowd.agent_get_neighbor(agent, j)
            if found {
                // Neighbor index should be in range [0,3] for cluster 1 agents
                testing.expect(t, neighbor.agent_index <= 3, 
                              "Cluster 1 agent should not see cluster 2 agents as neighbors")
            }
        }
    }
    
    // Similar test for cluster 2
    for i in 0..<len(cluster2_agents) {
        agent := crowd.crowd_get_agent(crowd_system, cluster2_agents[i])
        if agent == nil do continue
        
        neighbor_count := crowd.agent_get_neighbor_count(agent)
        testing.expect(t, neighbor_count > 0, "Cluster 2 agent should have neighbors")
        
        // Verify neighbors are from cluster 2
        for j in 0..<neighbor_count {
            neighbor, found := crowd.agent_get_neighbor(agent, j)
            if found {
                // Neighbor index should be in range [4,7] for cluster 2 agents
                testing.expect(t, neighbor.agent_index >= 4 && neighbor.agent_index <= 7,
                              "Cluster 2 agent should see other cluster 2 agents as neighbors")
            }
        }
    }
    
    fmt.printf("Proximity grid integration: item_count=%d\n", item_count)
}

@(test)
test_dynamic_spatial_updates :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 6)
    defer destroy_test_crowd(crowd_system)
    
    // Create agents that will move
    start_positions := [][3]f32{
        {5.0, 0.0, 15.0},   // Will move east
        {25.0, 0.0, 15.0},  // Will move west
        {15.0, 0.0, 5.0},   // Will move north
        {15.0, 0.0, 25.0},  // Will move south
    }
    
    targets := [][3]f32{
        {20.0, 0.0, 15.0},  // East target
        {10.0, 0.0, 15.0},  // West target  
        {15.0, 0.0, 20.0},  // North target
        {15.0, 0.0, 10.0},  // South target
    }
    
    agents := make([]recast.Agent_Id, len(start_positions))
    defer delete(agents)
    
    // Create agents and set targets
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    for pos, i in start_positions {
        agents[i] = add_test_agent(t, crowd_system, pos)
        
        _, target_ref, nearest_target := detour.find_nearest_poly(
            crowd_system.nav_query, targets[i], half_extents, filter
        )
        crowd.crowd_request_move_target(crowd_system, agents[i], target_ref, nearest_target)
    }
    
    // Track neighbor changes over time
    neighbor_history := make([]map[i32][]i32, 20)  // Store neighbor lists per frame
    defer {
        for &frame_data in neighbor_history {
            delete(frame_data)
        }
        delete(neighbor_history)
    }
    
    // Simulate movement and track spatial changes
    for frame in 0..<20 {
        crowd.crowd_update(crowd_system, 0.2, nil)
        
        // Record current neighbor state
        frame_neighbors := make(map[i32][]i32)
        
        for agent_id, i in agents {
            agent := crowd.crowd_get_agent(crowd_system, agent_id)
            if agent == nil do continue
            
            neighbor_count := crowd.agent_get_neighbor_count(agent)
            neighbors := make([]i32, neighbor_count)
            
            for j in 0..<neighbor_count {
                neighbor, found := crowd.agent_get_neighbor(agent, j)
                if found {
                    neighbors[j] = neighbor.agent_index
                }
            }
            
            frame_neighbors[i32(i)] = neighbors
        }
        
        neighbor_history[frame] = frame_neighbors
        
        // Log spatial state at key frames
        if frame % 5 == 0 {
            fmt.printf("Frame %d spatial state:\n", frame)
            for agent_id, i in agents {
                agent := crowd.crowd_get_agent(crowd_system, agent_id)
                if agent == nil do continue
                
                neighbors := frame_neighbors[i32(i)]
                fmt.printf("  Agent %d at (%.1f,%.1f): %d neighbors %v\n",
                          i, agent.position.x, agent.position.z, len(neighbors), neighbors)
            }
        }
    }
    
    // Analyze neighbor changes - agents should gain/lose neighbors as they move
    initial_neighbors := neighbor_history[0]
    final_neighbors := neighbor_history[19]
    
    neighbor_changes := 0
    for i in 0..<len(agents) {
        initial := initial_neighbors[i32(i)]
        final := final_neighbors[i32(i)]
        
        if !slice.equal(initial, final) {
            neighbor_changes += 1
        }
    }
    
    testing.expect(t, neighbor_changes > 0, "Should see neighbor relationship changes as agents move")
    
    fmt.printf("Dynamic spatial updates: %d agents changed neighbors during movement\n", neighbor_changes)
}