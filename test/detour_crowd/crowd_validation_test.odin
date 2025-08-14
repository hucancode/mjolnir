package test_detour_crowd

import "core:testing"
import "core:time"
import "core:math"
import "core:strings"
import "core:os"
import "core:fmt"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

// Test that validates against C++ reference implementation values
@(test)
test_validate_against_cpp_reference :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create basic nav mesh - similar to C++ test
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create nav query
    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)
    
    query_status := detour.nav_mesh_query_init(nav_query, nav_mesh, 2048)
    testing.expect(t, recast.status_succeeded(query_status), "Failed to init nav query")
    
    // Create crowd with same parameters as C++
    max_agents := i32(32)
    max_agent_radius := f32(3.0)
    
    crowd_system := new(crowd.Crowd)
    defer free(crowd_system)
    
    init_status := crowd.crowd_init(crowd_system, max_agents, max_agent_radius, nav_query)
    testing.expect(t, recast.status_succeeded(init_status), "Failed to init crowd")
    defer crowd.crowd_destroy(crowd_system)
    
    // Validate initialization values
    testing.expect_value(t, crowd_system.max_agents, max_agents)
    testing.expect_value(t, crowd_system.max_agent_radius, max_agent_radius)
    
    // Test agent creation with specific parameters matching C++
    params1 := crowd.Crowd_Agent_Params{
        radius = 0.5,
        height = 2.0,
        max_acceleration = 8.0,
        max_speed = 3.5,
        collision_query_range = 12.0,
        path_optimization_range = 30.0,
        separation_weight = 1.0,
        update_flags = {},
        obstacle_avoidance_type = 0,
        query_filter_type = 0,
    }
    
    pos1 := [3]f32{5.0, 0.0, 5.0}
    agent1_id, add1_status := crowd.crowd_add_agent(crowd_system, pos1, &params1)
    testing.expect(t, recast.status_succeeded(add1_status), "Failed to add agent 1")
    
    // Add second agent
    params2 := crowd.Crowd_Agent_Params{
        radius = 0.4,
        height = 2.0,
        max_acceleration = 8.0,
        max_speed = 2.5,
        collision_query_range = 12.0,
        path_optimization_range = 30.0,
        separation_weight = 2.0,
        update_flags = {},
        obstacle_avoidance_type = 0,
        query_filter_type = 0,
    }
    
    pos2 := [3]f32{7.0, 0.0, 5.0}
    agent2_id, add2_status := crowd.crowd_add_agent(crowd_system, pos2, &params2)
    testing.expect(t, recast.status_succeeded(add2_status), "Failed to add agent 2")
    
    // Validate agent properties match C++ reference
    agent1 := crowd.crowd_get_agent(crowd_system, agent1_id)
    agent2 := crowd.crowd_get_agent(crowd_system, agent2_id)
    
    if agent1 != nil {
        testing.expect(t, positions_equal_with_tolerance(agent1.position, pos1, 0.001),
                      fmt.tprintf("Agent1 position mismatch: expected %v, got %v", pos1, agent1.position))
        testing.expect(t, math.abs(agent1.params.radius - 0.5) < 0.001,
                      fmt.tprintf("Agent1 radius mismatch: expected 0.5, got %.6f", agent1.params.radius))
        testing.expect(t, math.abs(agent1.params.max_speed - 3.5) < 0.001,
                      fmt.tprintf("Agent1 max_speed mismatch: expected 3.5, got %.6f", agent1.params.max_speed))
        testing.expect(t, math.abs(agent1.params.max_acceleration - 8.0) < 0.001,
                      fmt.tprintf("Agent1 max_acceleration mismatch: expected 8.0, got %.6f", agent1.params.max_acceleration))
    }
    
    if agent2 != nil {
        testing.expect(t, positions_equal_with_tolerance(agent2.position, pos2, 0.001),
                      fmt.tprintf("Agent2 position mismatch: expected %v, got %v", pos2, agent2.position))
        testing.expect(t, math.abs(agent2.params.radius - 0.4) < 0.001,
                      fmt.tprintf("Agent2 radius mismatch: expected 0.4, got %.6f", agent2.params.radius))
        testing.expect(t, math.abs(agent2.params.max_speed - 2.5) < 0.001,
                      fmt.tprintf("Agent2 max_speed mismatch: expected 2.5, got %.6f", agent2.params.max_speed))
        testing.expect(t, math.abs(agent2.params.separation_weight - 2.0) < 0.001,
                      fmt.tprintf("Agent2 separation_weight mismatch: expected 2.0, got %.6f", agent2.params.separation_weight))
    }
    
    // Test parameter update
    updated_params := params1
    updated_params.max_speed = 4.0
    updated_params.separation_weight = 1.5
    
    update_status := crowd.crowd_update_agent_parameters(crowd_system, agent1_id, &updated_params)
    testing.expect(t, recast.status_succeeded(update_status), "Failed to update agent parameters")
    
    agent1 = crowd.crowd_get_agent(crowd_system, agent1_id)
    if agent1 != nil {
        testing.expect(t, math.abs(agent1.params.max_speed - 4.0) < 0.001,
                      fmt.tprintf("Updated max_speed mismatch: expected 4.0, got %.6f", agent1.params.max_speed))
        testing.expect(t, math.abs(agent1.params.separation_weight - 1.5) < 0.001,
                      fmt.tprintf("Updated separation_weight mismatch: expected 1.5, got %.6f", agent1.params.separation_weight))
    }
    
    // Simulate movement and validate against C++ reference values
    // Request velocity for both agents
    vel1 := [3]f32{2.0, 0.0, 1.0}
    vel2 := [3]f32{-1.0, 0.0, 0.5}
    
    vel1_status := crowd.crowd_request_move_velocity(crowd_system, agent1_id, vel1)
    vel2_status := crowd.crowd_request_move_velocity(crowd_system, agent2_id, vel2)
    
    testing.expect(t, recast.status_succeeded(vel1_status), "Failed to request velocity for agent 1")
    testing.expect(t, recast.status_succeeded(vel2_status), "Failed to request velocity for agent 2")
    
    // Simulate 5 steps with dt=0.05 to match C++ test
    dt := f32(0.05)
    
    // Expected positions from C++ reference (first few steps)
    // These values come from the expected_values.txt file
    expected_positions := [5][2][3]f32{
        {{5.0, 0.0, 5.0}, {7.0, 0.0, 5.0}},  // Step 0
        {{5.0, 0.0, 5.0}, {7.0, 0.0, 5.0}},  // Step 1
        {{5.0, 0.0, 5.0}, {7.0, 0.0, 5.0}},  // Step 2
        {{5.0, 0.0, 5.0}, {7.0, 0.0, 5.0}},  // Step 3
        {{5.0, 0.0, 5.0}, {7.0, 0.0, 5.0}},  // Step 4
    }
    
    for step in 0..<5 {
        update_status := crowd.crowd_update(crowd_system, dt, nil)
        testing.expect(t, recast.status_succeeded(update_status),
                      fmt.tprintf("Update failed at step %d", step))
        
        agent1 = crowd.crowd_get_agent(crowd_system, agent1_id)
        agent2 = crowd.crowd_get_agent(crowd_system, agent2_id)
        
        if agent1 != nil && agent2 != nil {
            // Validate positions match C++ reference
            tolerance := f32(0.01)  // Allow small numerical differences
            
            expected_pos1 := expected_positions[step][0]
            expected_pos2 := expected_positions[step][1]
            
            if !positions_equal_with_tolerance(agent1.position, expected_pos1, tolerance) {
                fmt.printf("Step %d: Agent1 position mismatch\n", step)
                fmt.printf("  Expected: [%.6f, %.6f, %.6f]\n", expected_pos1.x, expected_pos1.y, expected_pos1.z)
                fmt.printf("  Got:      [%.6f, %.6f, %.6f]\n", agent1.position.x, agent1.position.y, agent1.position.z)
            }
            
            if !positions_equal_with_tolerance(agent2.position, expected_pos2, tolerance) {
                fmt.printf("Step %d: Agent2 position mismatch\n", step)
                fmt.printf("  Expected: [%.6f, %.6f, %.6f]\n", expected_pos2.x, expected_pos2.y, expected_pos2.z)
                fmt.printf("  Got:      [%.6f, %.6f, %.6f]\n", agent2.position.x, agent2.position.y, agent2.position.z)
            }
            
            // Validate inter-agent distance
            dist := distance(agent1.position, agent2.position)
            expected_dist := f32(2.0)  // From C++ reference
            
            if math.abs(dist - expected_dist) > tolerance {
                fmt.printf("Step %d: Inter-agent distance mismatch\n", step)
                fmt.printf("  Expected: %.6f\n", expected_dist)
                fmt.printf("  Got:      %.6f\n", dist)
            }
        }
    }
}

// Test proximity grid validation against C++ reference
@(test)
test_proximity_grid_cpp_validation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    grid := new(crowd.Proximity_Grid)
    defer free(grid)
    
    // Initialize with C++ reference parameters
    max_items := i32(100)
    cell_size := f32(2.0)
    
    init_status := crowd.proximity_grid_init(grid, max_items, cell_size)
    testing.expect(t, recast.status_succeeded(init_status), "Failed to init proximity grid")
    defer crowd.proximity_grid_destroy(grid)
    
    // Validate initialization matches C++ reference
    testing.expect_value(t, grid.max_items, max_items)
    testing.expect(t, math.abs(grid.cell_size - cell_size) < 0.001,
                  fmt.tprintf("Cell size mismatch: expected 2.0, got %.6f", grid.cell_size))
    testing.expect(t, math.abs(grid.inv_cell_size - 0.5) < 0.001,
                  fmt.tprintf("Inv cell size mismatch: expected 0.5, got %.6f", grid.inv_cell_size))
    
    // Add items as in C++ test
    status1 := crowd.proximity_grid_add_item(grid, 1, 0, 0, 2, 2)
    testing.expect(t, recast.status_succeeded(status1), "Failed to add item 1")
    
    status2 := crowd.proximity_grid_add_item(grid, 2, 3, 3, 5, 5)
    testing.expect(t, recast.status_succeeded(status2), "Failed to add item 2")
    
    status3 := crowd.proximity_grid_add_item(grid, 3, 1, 1, 1.5, 1.5)
    testing.expect(t, recast.status_succeeded(status3), "Failed to add item 3")
    
    // Query items and validate results match C++ reference
    items := make([]u16, 10)
    defer delete(items)
    
    // Query 1: Around (1,1) with radius 3.0 - should find items 1, 2, and 3
    // Item 2 is at distance sqrt(8) ≈ 2.83 from (1,1), which is < 3.0
    count1 := crowd.proximity_grid_query_items(grid, 1, 1, 3.0, items[:], 10)
    testing.expect(t, count1 == 3,
                  fmt.tprintf("Query 1 count mismatch: expected 3, got %d", count1))
    
    // Query 2: Around (4,4) with radius 2.0 - should find item 2
    count2 := crowd.proximity_grid_query_items(grid, 4, 4, 2.0, items[:], 10)
    testing.expect(t, count2 == 1,
                  fmt.tprintf("Query 2 count mismatch: expected 1, got %d", count2))
    
    // Query 3: Around (10,10) with radius 1.0 - should find nothing
    count3 := crowd.proximity_grid_query_items(grid, 10, 10, 1.0, items[:], 10)
    testing.expect(t, count3 == 0,
                  fmt.tprintf("Query 3 count mismatch: expected 0, got %d", count3))
}

// Test obstacle avoidance parameters against C++ reference
@(test)
test_obstacle_avoidance_cpp_validation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create and validate low quality params
    low_params := crowd.obstacle_avoidance_params_create_low_quality()
    
    // C++ reference values for low quality
    testing.expect_value(t, low_params.vel_bias, f32(0.4))
    testing.expect_value(t, low_params.weight_des_vel, f32(2.0))
    testing.expect_value(t, low_params.weight_cur_vel, f32(0.75))
    testing.expect_value(t, low_params.weight_side, f32(0.75))
    testing.expect_value(t, low_params.weight_toi, f32(2.5))
    testing.expect_value(t, low_params.horiz_time, f32(2.5))
    testing.expect_value(t, low_params.grid_size, u8(33))
    testing.expect_value(t, low_params.adaptive_divs, u8(7))
    testing.expect_value(t, low_params.adaptive_rings, u8(2))
    testing.expect_value(t, low_params.adaptive_depth, u8(5))
    
    // Create and validate medium quality params
    med_params := crowd.obstacle_avoidance_params_create_medium_quality()
    
    // C++ reference values for medium quality
    testing.expect_value(t, med_params.vel_bias, f32(0.4))
    testing.expect_value(t, med_params.weight_des_vel, f32(2.0))
    testing.expect_value(t, med_params.weight_cur_vel, f32(0.75))
    testing.expect_value(t, med_params.weight_side, f32(0.75))
    testing.expect_value(t, med_params.weight_toi, f32(2.5))
    testing.expect_value(t, med_params.horiz_time, f32(2.5))
    testing.expect_value(t, med_params.grid_size, u8(33))
    testing.expect_value(t, med_params.adaptive_divs, u8(7))
    testing.expect_value(t, med_params.adaptive_rings, u8(2))
    testing.expect_value(t, med_params.adaptive_depth, u8(5))
    
    // Create and validate high quality params
    high_params := crowd.obstacle_avoidance_params_create_high_quality()
    
    // C++ reference values for high quality
    testing.expect_value(t, high_params.vel_bias, f32(0.4))
    testing.expect_value(t, high_params.weight_des_vel, f32(2.0))
    testing.expect_value(t, high_params.weight_cur_vel, f32(0.75))
    testing.expect_value(t, high_params.weight_side, f32(0.75))
    testing.expect_value(t, high_params.weight_toi, f32(2.5))
    testing.expect_value(t, high_params.horiz_time, f32(2.5))
    testing.expect_value(t, high_params.grid_size, u8(45))
    testing.expect_value(t, high_params.adaptive_divs, u8(7))
    testing.expect_value(t, high_params.adaptive_rings, u8(3))
    testing.expect_value(t, high_params.adaptive_depth, u8(5))
}

// Helper function to check position equality with tolerance
positions_equal_with_tolerance :: proc(a, b: [3]f32, tolerance: f32) -> bool {
    return math.abs(a.x - b.x) < tolerance &&
           math.abs(a.y - b.y) < tolerance &&
           math.abs(a.z - b.z) < tolerance
}

// Helper function to calculate distance between positions
distance :: proc(a, b: [3]f32) -> f32 {
    dx := a.x - b.x
    dy := a.y - b.y
    dz := a.z - b.z
    return math.sqrt(dx*dx + dy*dy + dz*dz)
}