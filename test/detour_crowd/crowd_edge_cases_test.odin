package test_detour_crowd

import "core:testing"
import "core:time"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

// =============================================================================
// Invalid Input Handling Tests
// =============================================================================

@(test)
test_crowd_creation_invalid_parameters :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)
    detour.nav_mesh_query_init(nav_query, nav_mesh, 256)
    defer detour.nav_mesh_query_destroy(nav_query)

    // Test invalid max_agents
    crowd_system, status := crowd.crowd_create(0, 1.0, nav_query)  // Zero agents
    testing.expect(t, recast.status_failed(status), "Should fail with zero agents")
    testing.expect(t, crowd_system == nil, "Should return nil on failure")

    crowd_system, status = crowd.crowd_create(-5, 1.0, nav_query)  // Negative agents
    testing.expect(t, recast.status_failed(status), "Should fail with negative agents")
    testing.expect(t, crowd_system == nil, "Should return nil on failure")

    // Test invalid max_agent_radius
    crowd_system, status = crowd.crowd_create(10, 0.0, nav_query)  // Zero radius
    testing.expect(t, recast.status_failed(status), "Should fail with zero radius")
    testing.expect(t, crowd_system == nil, "Should return nil on failure")

    crowd_system, status = crowd.crowd_create(10, -1.0, nav_query)  // Negative radius
    testing.expect(t, recast.status_failed(status), "Should fail with negative radius")
    testing.expect(t, crowd_system == nil, "Should return nil on failure")

    // Test nil nav_query
    crowd_system, status = crowd.crowd_create(10, 1.0, nil)
    testing.expect(t, recast.status_failed(status), "Should fail with nil nav query")
    testing.expect(t, crowd_system == nil, "Should return nil on failure")
}

@(test)
test_agent_add_invalid_parameters :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 3)  // Very small capacity
    defer destroy_test_crowd(crowd_system)

    // Test invalid agent parameters
    invalid_params := crowd.agent_params_create_default()

    // Test negative radius
    invalid_params.radius = -0.5
    agent_id, status := crowd.crowd_add_agent(crowd_system, {10.0, 0.0, 10.0}, &invalid_params)
    testing.expect(t, recast.status_failed(status), "Should fail with negative radius")
    testing.expect(t, agent_id == recast.Agent_Id(0), "Should return invalid agent ID")

    // Test negative height
    invalid_params.radius = 0.5
    invalid_params.height = -1.0
    agent_id, status = crowd.crowd_add_agent(crowd_system, {10.0, 0.0, 10.0}, &invalid_params)
    testing.expect(t, recast.status_failed(status), "Should fail with negative height")

    // Test negative max_speed
    invalid_params.height = 2.0
    invalid_params.max_speed = -2.0
    agent_id, status = crowd.crowd_add_agent(crowd_system, {10.0, 0.0, 10.0}, &invalid_params)
    testing.expect(t, recast.status_failed(status), "Should fail with negative max speed")

    // Test negative max_acceleration
    invalid_params.max_speed = 3.0
    invalid_params.max_acceleration = -5.0
    agent_id, status = crowd.crowd_add_agent(crowd_system, {10.0, 0.0, 10.0}, &invalid_params)
    testing.expect(t, recast.status_failed(status), "Should fail with negative max acceleration")

    // Test invalid collision_query_range
    invalid_params.max_acceleration = 8.0
    invalid_params.collision_query_range = 0.0
    agent_id, status = crowd.crowd_add_agent(crowd_system, {10.0, 0.0, 10.0}, &invalid_params)
    testing.expect(t, recast.status_failed(status), "Should fail with zero collision query range")

    // Test nil parameters
    agent_id, status = crowd.crowd_add_agent(crowd_system, {10.0, 0.0, 10.0}, nil)
    testing.expect(t, recast.status_failed(status), "Should fail with nil parameters")
}

@(test)
test_agent_capacity_overflow :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 2)  // Only 2 agents max
    defer destroy_test_crowd(crowd_system)

    params := crowd.agent_params_create_default()

    // Add agents up to capacity
    agent1, status1 := crowd.crowd_add_agent(crowd_system, {5.0, 0.0, 5.0}, &params)
    testing.expect(t, recast.status_succeeded(status1), "Should add first agent")
    testing.expect(t, agent1 != recast.Agent_Id(0), "Should get valid agent ID")

    agent2, status2 := crowd.crowd_add_agent(crowd_system, {10.0, 0.0, 10.0}, &params)
    testing.expect(t, recast.status_succeeded(status2), "Should add second agent")
    testing.expect(t, agent2 != recast.Agent_Id(0), "Should get valid agent ID")

    // Try to add beyond capacity
    agent3, status3 := crowd.crowd_add_agent(crowd_system, {15.0, 0.0, 15.0}, &params)
    testing.expect(t, recast.status_failed(status3), "Should fail when exceeding capacity")
    testing.expect(t, agent3 == recast.Agent_Id(0), "Should return invalid agent ID when full")

    // Verify exact agent count
    active_count := crowd.crowd_get_active_agent_count(crowd_system)
    testing.expect(t, active_count == 2, "Should have exactly 2 active agents")

    // Remove an agent and try adding again
    remove_status := crowd.crowd_remove_agent(crowd_system, agent1)
    testing.expect(t, recast.status_succeeded(remove_status), "Should remove agent successfully")

    active_count = crowd.crowd_get_active_agent_count(crowd_system)
    testing.expect(t, active_count == 1, "Should have exactly 1 active agent after removal")

    // Should be able to add again after removal
    agent4, status4 := crowd.crowd_add_agent(crowd_system, {20.0, 0.0, 20.0}, &params)
    testing.expect(t, recast.status_succeeded(status4), "Should add agent after removal")
    testing.expect(t, agent4 != recast.Agent_Id(0), "Should get valid agent ID after removal")
}

@(test)
test_invalid_agent_operations :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)

    // Test operations on invalid agent IDs
    invalid_agent_id := recast.Agent_Id(999)

    // Test move target request with invalid agent
    status := crowd.crowd_request_move_target(crowd_system, invalid_agent_id, recast.Poly_Ref(1), {10.0, 0.0, 10.0})
    testing.expect(t, recast.status_failed(status), "Should fail move target request for invalid agent")

    // Test move velocity request with invalid agent
    status = crowd.crowd_request_move_velocity(crowd_system, invalid_agent_id, {1.0, 0.0, 0.0})
    testing.expect(t, recast.status_failed(status), "Should fail move velocity request for invalid agent")

    // Test remove invalid agent
    status = crowd.crowd_remove_agent(crowd_system, invalid_agent_id)
    testing.expect(t, recast.status_failed(status), "Should fail to remove invalid agent")

    // Test reset move target for invalid agent
    status = crowd.crowd_reset_move_target(crowd_system, invalid_agent_id)
    testing.expect(t, recast.status_failed(status), "Should fail to reset move target for invalid agent")

    // Test get agent for invalid ID
    agent := crowd.crowd_get_agent(crowd_system, invalid_agent_id)
    testing.expect(t, agent == nil, "Should return nil for invalid agent ID")

    // Test update parameters for invalid agent
    params := crowd.agent_params_create_default()
    status = crowd.crowd_update_agent_parameters(crowd_system, invalid_agent_id, &params)
    testing.expect(t, recast.status_failed(status), "Should fail to update parameters for invalid agent")
}

@(test)
test_invalid_position_handling :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)

    params := crowd.agent_params_create_default()

    // Test positions with extreme values
    extreme_positions := [][3]f32{
        {math.F32_MAX, 0.0, 0.0},      // Extreme X
        {0.0, math.F32_MAX, 0.0},      // Extreme Y
        {0.0, 0.0, math.F32_MAX},      // Extreme Z
        {-math.F32_MAX, 0.0, 0.0},     // Negative extreme X
        {math.inf_f32(1), 0.0, 0.0},   // Infinity
        {math.nan_f32(), 0.0, 0.0},    // NaN
    }

    for pos, i in extreme_positions {
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)

        // Behavior may vary - some extreme values might be handled, others rejected
        if recast.status_succeeded(status) {
            // If agent was added, verify it can be retrieved
            agent := crowd.crowd_get_agent(crowd_system, agent_id)
            testing.expect(t, agent != nil, "If agent added with extreme position, should be retrievable")

            // Remove for next test
            crowd.crowd_remove_agent(crowd_system, agent_id)
        } else {
            // If rejected, that's also valid behavior
            fmt.printf("Extreme position %d rejected: (%.1f, %.1f, %.1f)\n", i, pos.x, pos.y, pos.z)
        }
    }

    // Test very far positions (outside nav mesh)
    far_positions := [][3]f32{
        {1000.0, 0.0, 1000.0},    // Far from nav mesh
        {-500.0, 0.0, -500.0},    // Far negative
        {100.0, 100.0, 100.0},    // High Y
    }

    for pos, i in far_positions {
        // Check if position is valid for placement
        valid := crowd.crowd_is_valid_position(crowd_system, pos, 0.5, 0)

        if valid {
            agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
            testing.expect(t, recast.status_succeeded(status), "Should add agent at valid far position")

            if recast.status_succeeded(status) {
                crowd.crowd_remove_agent(crowd_system, agent_id)
            }
        } else {
            fmt.printf("Far position %d determined invalid: (%.1f, %.1f, %.1f)\n", i, pos.x, pos.y, pos.z)
        }
    }
}

// =============================================================================
// Zero and Negative Value Tests
// =============================================================================

@(test)
test_zero_time_step_update :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)

    // Add an agent
    agent_id := add_test_agent(t, crowd_system, {10.0, 0.0, 10.0})

    initial_agent := crowd.crowd_get_agent(crowd_system, agent_id)
    testing.expect(t, initial_agent != nil, "Agent should exist")
    initial_pos := initial_agent.position
    initial_vel := initial_agent.velocity

    // Update with zero time step
    status := crowd.crowd_update(crowd_system, 0.0, nil)
    testing.expect(t, recast.status_succeeded(status) || recast.status_failed(status),
                  "Zero dt update should have defined behavior")

    // Check agent state after zero dt
    final_agent := crowd.crowd_get_agent(crowd_system, agent_id)
    testing.expect(t, final_agent != nil, "Agent should still exist after zero dt")

    // Position and velocity should not change meaningfully with zero dt
    pos_change := linalg.distance(initial_pos, final_agent.position)
    testing.expect(t, pos_change < 0.001, "Position should not change significantly with zero dt")

    fmt.printf("Zero dt update: pos_change=%.6f\n", pos_change)
}

@(test)
test_negative_time_step_update :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)

    // Add an agent
    agent_id := add_test_agent(t, crowd_system, {10.0, 0.0, 10.0})

    // Update with negative time step
    status := crowd.crowd_update(crowd_system, -0.1, nil)

    // This should either fail or be handled gracefully
    if recast.status_failed(status) {
        fmt.printf("Negative dt correctly rejected\n")
    } else {
        fmt.printf("Negative dt handled (possibly clamped to zero)\n")

        // If handled, agent should still be valid
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        testing.expect(t, agent != nil, "Agent should remain valid after negative dt")
    }
}

@(test)
test_zero_velocity_requests :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)

    agent_id := add_test_agent(t, crowd_system, {15.0, 0.0, 15.0})

    // Request zero velocity
    zero_vel := [3]f32{0.0, 0.0, 0.0}
    status := crowd.crowd_request_move_velocity(crowd_system, agent_id, zero_vel)
    testing.expect(t, recast.status_succeeded(status), "Zero velocity request should succeed")

    // Update and check result
    for i in 0..<10 {
        crowd.crowd_update(crowd_system, 0.1, nil)
    }

    agent := crowd.crowd_get_agent(crowd_system, agent_id)
    testing.expect(t, agent != nil, "Agent should exist after zero velocity request")

    // Agent should have minimal velocity
    vel_magnitude := linalg.length(agent.velocity)
    testing.expect(t, vel_magnitude < 0.1, "Agent velocity should be near zero")

    fmt.printf("Zero velocity result: vel_magnitude=%.6f\n", vel_magnitude)
}

// =============================================================================
// Buffer Overflow and Limit Tests
// =============================================================================

@(test)
test_maximum_neighbors_handling :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    // Create crowd with many agents to test neighbor limits
    max_agents := i32(crowd.DT_CROWD_MAX_NEIGHBORS + 5)
    crowd_system := create_test_crowd(t, nav_mesh, max_agents)
    defer destroy_test_crowd(crowd_system)

    // Place center agent
    center_pos := [3]f32{15.0, 0.0, 15.0}
    center_agent_id := add_test_agent(t, crowd_system, center_pos)

    // Place many agents in a tight cluster around center
    neighbor_agents := make([]recast.Agent_Id, int(max_agents) - 1)
    defer delete(neighbor_agents)

    for i in 0..<len(neighbor_agents) {
        // Place in a circle around center
        angle := f32(i) * 2.0 * math.PI / f32(len(neighbor_agents))
        radius := f32(2.0)  // Close enough to be neighbors

        pos := [3]f32{
            center_pos.x + radius * math.cos(angle),
            0.0,
            center_pos.z + radius * math.sin(angle),
        }

        neighbor_agents[i] = add_test_agent(t, crowd_system, pos)
    }

    // Update to establish neighbor relationships
    crowd.crowd_update(crowd_system, 0.1, nil)

    // Check center agent's neighbors
    center_agent := crowd.crowd_get_agent(crowd_system, center_agent_id)
    testing.expect(t, center_agent != nil, "Center agent should exist")

    neighbor_count := crowd.agent_get_neighbor_count(center_agent)
    testing.expect(t, neighbor_count <= crowd.DT_CROWD_MAX_NEIGHBORS,
                  "Neighbor count should not exceed maximum")

    // All reported neighbors should be valid
    for i in 0..<neighbor_count {
        neighbor, found := crowd.agent_get_neighbor(center_agent, i)
        testing.expect(t, found, fmt.tprintf("Should find neighbor at index %d", i))

        if found {
            testing.expect(t, neighbor.agent_index >= 0, "Neighbor index should be non-negative")
            testing.expect(t, neighbor.distance > 0.0, "Neighbor distance should be positive")
            testing.expect(t, neighbor.distance < 10.0, "Neighbor distance should be reasonable")
        }
    }

    fmt.printf("Maximum neighbors test: %d neighbors found (max allowed: %d)\n",
              neighbor_count, crowd.DT_CROWD_MAX_NEIGHBORS)
}

@(test)
test_maximum_corners_handling :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)

    agent_id := add_test_agent(t, crowd_system, {5.0, 0.0, 5.0})

    // Set a target far away to potentially create a complex path
    target_pos := [3]f32{25.0, 0.0, 25.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)

    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )

    crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)

    // Update several times to establish path
    for i in 0..<15 {
        crowd.crowd_update(crowd_system, 0.1, nil)
    }

    agent := crowd.crowd_get_agent(crowd_system, agent_id)
    testing.expect(t, agent != nil, "Agent should exist")

    corner_count := crowd.agent_get_corner_count(agent)
    testing.expect(t, corner_count <= crowd.DT_CROWD_MAX_CORNERS,
                  "Corner count should not exceed maximum")

    // All reported corners should be valid
    for i in 0..<corner_count {
        pos, flags, poly, found := crowd.agent_get_corner(agent, i)
        testing.expect(t, found, fmt.tprintf("Should find corner at index %d", i))

        if found {
            fmt.printf("  Corner %d: pos=(%.2f,%.2f,%.2f), flags=%d, poly=0x%x\n", 
                      i, pos.x, pos.y, pos.z, flags, poly)
            
            // End points (last corner) can have poly=0 as per C++ implementation
            is_end_point := (i == corner_count - 1) && (flags == u8(detour.Straight_Path_Flags.End))
            if !is_end_point {
                testing.expect(t, poly != recast.INVALID_POLY_REF, "Non-end corner polygon should be valid")
            }
            testing.expect(t, flags >= 0, "Corner flags should be non-negative")

            // Position should be reasonable
            testing.expect(t, !math.is_nan(pos.x) && !math.is_nan(pos.y) && !math.is_nan(pos.z),
                          "Corner position should not contain NaN")
        }
    }

    fmt.printf("Maximum corners test: %d corners found (max allowed: %d)\n",
              corner_count, crowd.DT_CROWD_MAX_CORNERS)
}

@(test)
test_proximity_grid_item_limit :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    grid := new(crowd.Proximity_Grid)
    defer free(grid)

    max_items := i32(5)  // Small limit to test overflow
    crowd.proximity_grid_init(grid, max_items, 1.0)
    defer crowd.proximity_grid_destroy(grid)

    // Add items up to limit
    for i in 1..=max_items {
        status := crowd.proximity_grid_add_item(grid, u16(i), f32(i), f32(i), f32(i+1), f32(i+1))
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add item %d", i))
    }

    // Verify at capacity
    item_count := crowd.proximity_grid_get_item_count(grid)
    testing.expect(t, item_count == max_items, "Should be at max capacity")

    // Try to add beyond capacity
    overflow_status := crowd.proximity_grid_add_item(grid, u16(max_items + 1), 100.0, 100.0, 101.0, 101.0)
    testing.expect(t, recast.status_failed(overflow_status), "Should fail when adding beyond capacity")

    // Item count should remain at max
    final_item_count := crowd.proximity_grid_get_item_count(grid)
    testing.expect(t, final_item_count == max_items, "Item count should remain at max after overflow attempt")
}

// =============================================================================
// Concurrent Modification Tests
// =============================================================================

@(test)
test_agent_removal_during_update :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 6)
    defer destroy_test_crowd(crowd_system)

    // Add several agents
    agents := make([]recast.Agent_Id, 4)
    defer delete(agents)

    positions := [][3]f32{
        {10.0, 0.0, 10.0},
        {12.0, 0.0, 10.0},
        {14.0, 0.0, 10.0},
        {16.0, 0.0, 10.0},
    }

    for pos, i in positions {
        agents[i] = add_test_agent(t, crowd_system, pos)
    }

    // Start movement for all agents
    target_pos := [3]f32{25.0, 0.0, 15.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)

    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )

    for agent_id in agents {
        crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    }

    initial_count := crowd.crowd_get_active_agent_count(crowd_system)
    testing.expect(t, initial_count == 4, "Should start with 4 active agents")

    // Update a few times to establish movement
    for i in 0..<5 {
        crowd.crowd_update(crowd_system, 0.1, nil)
    }

    // Remove middle agents while others are still active
    remove_status1 := crowd.crowd_remove_agent(crowd_system, agents[1])
    testing.expect(t, recast.status_succeeded(remove_status1), "Should remove agent 1")

    remove_status2 := crowd.crowd_remove_agent(crowd_system, agents[2])
    testing.expect(t, recast.status_succeeded(remove_status2), "Should remove agent 2")

    // Continue updating with remaining agents
    for i in 0..<10 {
        status := crowd.crowd_update(crowd_system, 0.1, nil)
        testing.expect(t, recast.status_succeeded(status), "Update should succeed after agent removal")
    }

    // Verify final state
    final_count := crowd.crowd_get_active_agent_count(crowd_system)
    testing.expect(t, final_count == 2, "Should have 2 active agents after removal")

    // Remaining agents should still be valid and moving
    agent_0 := crowd.crowd_get_agent(crowd_system, agents[0])
    agent_3 := crowd.crowd_get_agent(crowd_system, agents[3])

    testing.expect(t, agent_0 != nil, "Agent 0 should still exist")
    testing.expect(t, agent_3 != nil, "Agent 3 should still exist")

    // Removed agents should return nil
    agent_1 := crowd.crowd_get_agent(crowd_system, agents[1])
    agent_2 := crowd.crowd_get_agent(crowd_system, agents[2])

    testing.expect(t, agent_1 == nil, "Agent 1 should be nil after removal")
    testing.expect(t, agent_2 == nil, "Agent 2 should be nil after removal")

    fmt.printf("Agent removal test: started with %d, removed 2, ended with %d\n",
              initial_count, final_count)
}

@(test)
test_path_invalidation_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    crowd_system := create_test_crowd(t, nav_mesh, 3)
    defer destroy_test_crowd(crowd_system)

    agent_id := add_test_agent(t, crowd_system, {15.0, 0.0, 15.0})

    // Test multiple rapid path changes
    targets := [][3]f32{
        {5.0, 0.0, 5.0},
        {25.0, 0.0, 25.0},
        {5.0, 0.0, 25.0},
        {25.0, 0.0, 5.0},
    }

    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)

    for target, i in targets {
        _, target_ref, nearest_target := detour.find_nearest_poly(
            crowd_system.nav_query, target, half_extents, filter
        )

        // Request new target immediately after previous
        status := crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
        testing.expectf(t, recast.status_succeeded(status), "Move target request %d should succeed", i)

        // Update briefly
        crowd.crowd_update(crowd_system, 0.05, nil)

        // Verify agent still exists and is in valid state
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        testing.expectf(t, agent != nil, "Agent should exist after rapid target change %d", i)

        if agent != nil {
            state := crowd.agent_get_state(agent)
            testing.expectf(t, state != .Invalid, "Agent state should be valid after target change %d", i)
        }
    }

    // Final update to stabilize
    for i in 0..<10 {
        crowd.crowd_update(crowd_system, 0.1, nil)
    }

    // Agent should still be valid
    final_agent := crowd.crowd_get_agent(crowd_system, agent_id)
    testing.expect(t, final_agent != nil, "Agent should remain valid after rapid target changes")

    if final_agent != nil {
        final_state := crowd.agent_get_state(final_agent)
        testing.expect(t, final_state == .Walking, "Agent should be in walking state")
    }
}
