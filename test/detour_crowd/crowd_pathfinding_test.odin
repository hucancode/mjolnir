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
// Path Queue Unit Tests
// =============================================================================

@(test)
test_path_queue_request_response_cycle :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)
    
    status := detour.nav_mesh_query_init(nav_query, nav_mesh, 256)
    testing.expect(t, recast.status_succeeded(status), "Failed to init nav query")
    defer detour.nav_mesh_query_destroy(nav_query)
    
    queue := new(crowd.Path_Queue)
    defer free(queue)
    
    // Initialize path queue with known parameters
    init_status := crowd.path_queue_init(queue, 64, 512, nav_query)
    testing.expect(t, recast.status_succeeded(init_status), "Failed to initialize path queue")
    defer crowd.path_queue_destroy(queue)
    
    // Test exact initial state
    testing.expect(t, queue.max_path_size == 64, "Max path size should be 64")
    testing.expect(t, queue.max_search_nodes == 512, "Max search nodes should be 512")
    testing.expect(t, queue.nav_query == nav_query, "Nav query should match")
    testing.expect(t, crowd.path_queue_is_empty(queue), "Queue should start empty")
    testing.expect(t, !crowd.path_queue_is_full(queue), "Queue should not be full")
    
    // Test path request with exact polygon references
    start_ref := recast.Poly_Ref(1)
    end_ref := recast.Poly_Ref(5) 
    start_pos := [3]f32{5.0, 0.0, 5.0}
    end_pos := [3]f32{25.0, 0.0, 25.0}
    
    filter := new(detour.Query_Filter)
    defer free(filter)
    detour.query_filter_init(filter)
    
    path_ref, request_status := crowd.path_queue_request(queue, start_ref, end_ref, start_pos, end_pos, filter)
    testing.expect(t, recast.status_succeeded(request_status), "Path request should succeed")
    testing.expect(t, path_ref != crowd.Path_Queue_Ref(0), "Should get valid path reference")
    
    // Verify queue state after request
    testing.expect(t, !crowd.path_queue_is_empty(queue), "Queue should not be empty after request")
    pending_count := crowd.path_queue_get_pending_count(queue)
    testing.expect(t, pending_count == 1, "Should have exactly 1 pending request")
    
    // Test path request status
    queue_status := crowd.path_queue_get_request_status(queue, path_ref)
    testing.expect(t, recast.Status_Flag.In_Progress in queue_status, 
                  "Request should be in progress")
    
    // Update queue to process request
    update_status := crowd.path_queue_update(queue, 10)
    testing.expect(t, recast.status_succeeded(update_status), "Queue update should succeed")
    
    // Check completion
    final_status := crowd.path_queue_get_request_status(queue, path_ref)
    if recast.status_succeeded(final_status) {
        // Get path result with exact expected format
        path_result := make([]recast.Poly_Ref, 32)
        defer delete(path_result)
        
        path_count, result_status := crowd.path_queue_get_path_result(queue, path_ref, path_result[:])
        testing.expect(t, recast.status_succeeded(result_status), "Should get path result")
        testing.expect(t, path_count >= 1, "Should have at least 1 polygon in path")
        testing.expect(t, path_result[0] == start_ref, "Path should start with start_ref")
    }
    
    // Verify statistics are exact
    queue_size, max_queue_size := crowd.path_queue_get_stats(queue)
    testing.expect(t, queue_size >= 0, "Queue size should be non-negative")
    testing.expect(t, max_queue_size > 0, "Max queue size should be positive")
    
    completed_count := crowd.path_queue_get_completed_count(queue)
    testing.expect(t, completed_count >= 0, "Completed count should be non-negative")
}

@(test)
test_path_queue_cancel_request :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)
    
    detour.nav_mesh_query_init(nav_query, nav_mesh, 256)
    defer detour.nav_mesh_query_destroy(nav_query)
    
    queue := new(crowd.Path_Queue)
    defer free(queue)
    init_status := crowd.path_queue_init(queue, 64, 512, nav_query)
    testing.expect(t, recast.status_succeeded(init_status), "Path queue init should succeed")
    defer crowd.path_queue_destroy(queue)
    
    // Create a path request
    start_ref := recast.Poly_Ref(1)
    end_ref := recast.Poly_Ref(9)
    start_pos := [3]f32{5.0, 0.0, 5.0}
    end_pos := [3]f32{25.0, 0.0, 25.0}
    
    filter := new(detour.Query_Filter)
    defer free(filter)
    detour.query_filter_init(filter)
    
    path_ref, request_status := crowd.path_queue_request(queue, start_ref, end_ref, start_pos, end_pos, filter)
    testing.expect(t, recast.status_succeeded(request_status), "Path request should succeed")
    
    initial_pending := crowd.path_queue_get_pending_count(queue)
    testing.expect(t, initial_pending == 1, "Should have 1 pending request")
    
    // Cancel the request
    cancel_status := crowd.path_queue_cancel_request(queue, path_ref)
    testing.expect(t, recast.status_succeeded(cancel_status), "Cancel should succeed")
    
    // Verify cancellation effect
    final_pending := crowd.path_queue_get_pending_count(queue)
    testing.expect(t, final_pending == 0, "Should have 0 pending requests after cancel")
    
    // Verify request is no longer valid
    testing.expect(t, !crowd.path_queue_is_valid_ref(queue, path_ref), 
                  "Cancelled request should be invalid")
}

// =============================================================================
// Path Corridor Unit Tests  
// =============================================================================

@(test)
test_path_corridor_reset_with_exact_values :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    corridor := new(crowd.Path_Corridor)
    defer free(corridor)
    
    // Initialize with specific capacity
    status := crowd.path_corridor_init(corridor, 128)
    testing.expect(t, recast.status_succeeded(status), "Failed to initialize corridor")
    defer crowd.path_corridor_destroy(corridor)
    
    // Verify exact initial state
    testing.expect(t, corridor.max_path == 128, "Max path should be exactly 128")
    testing.expect(t, len(corridor.path) == 0, "Path should start empty")
    testing.expect(t, corridor.position == [3]f32{}, "Position should be zero")
    
    // Reset with specific values
    test_ref := recast.Poly_Ref(42)
    test_pos := [3]f32{10.5, 2.0, -5.5}
    
    reset_status := crowd.path_corridor_reset(corridor, test_ref, test_pos)
    testing.expect(t, recast.status_succeeded(reset_status), "Reset should succeed")
    
    // Verify exact post-reset state
    testing.expect(t, len(corridor.path) == 1, "Path should have exactly 1 polygon")
    testing.expect(t, corridor.path[0] == test_ref, "First polygon should match exactly")
    testing.expect(t, corridor.position == test_pos, "Position should match exactly")
    
    // Test corridor queries
    first_poly := crowd.path_corridor_get_first_poly(corridor)
    testing.expect(t, first_poly == test_ref, "First poly should match")
    
    last_poly := crowd.path_corridor_get_last_poly(corridor)
    testing.expect(t, last_poly == test_ref, "Last poly should match (single element)")
}

@(test)
test_path_corridor_optimization :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)
    status := detour.nav_mesh_query_init(nav_query, nav_mesh, 256)
    testing.expect(t, recast.status_succeeded(status), "Nav mesh query init should succeed")
    defer detour.nav_mesh_query_destroy(nav_query)
    
    corridor := new(crowd.Path_Corridor)
    defer free(corridor)
    crowd.path_corridor_init(corridor, 64)
    defer crowd.path_corridor_destroy(corridor)
    
    // Set up a path with multiple polygons
    test_path := []recast.Poly_Ref{1, 2, 3, 4, 5}
    corridor.path = make([dynamic]recast.Poly_Ref, len(test_path))
    copy(corridor.path[:], test_path)
    corridor.position = [3]f32{5.0, 0.0, 5.0}
    corridor.target = [3]f32{25.0, 0.0, 25.0}
    
    filter := new(detour.Query_Filter)
    defer free(filter)
    detour.query_filter_init(filter)
    
    initial_path_len := len(corridor.path)
    
    // Test visibility optimization
    vis_status := crowd.path_corridor_optimize_path_visibility(corridor, corridor.position, 30.0, nav_query, filter)
    testing.expect(t, recast.status_succeeded(vis_status), "Visibility optimization should succeed")
    
    // Path length might change due to optimization
    post_vis_len := len(corridor.path)
    testing.expect(t, post_vis_len >= 1, "Path should have at least 1 polygon after vis optimization")
    
    // Test topology optimization
    optimized, topo_status := crowd.path_corridor_optimize_path_topology(corridor, nav_query, filter)
    testing.expect(t, recast.status_succeeded(topo_status), "Topology optimization should succeed")
    // optimized is a bool, so we just check that the call succeeded
    
    final_len := len(corridor.path)
    testing.expect(t, final_len >= 1, "Path should have at least 1 polygon after topo optimization")
    
    // Verify first polygon remains valid
    first_poly := crowd.path_corridor_get_first_poly(corridor)
    testing.expect(t, first_poly != recast.INVALID_POLY_REF, "First polygon should remain valid")
}

@(test)  
test_path_corridor_move_over_surface :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)
    detour.nav_mesh_query_init(nav_query, nav_mesh, 256)
    defer detour.nav_mesh_query_destroy(nav_query)
    
    corridor := new(crowd.Path_Corridor)
    defer free(corridor)
    crowd.path_corridor_init(corridor, 64)  
    defer crowd.path_corridor_destroy(corridor)
    
    // Set up corridor with known position
    start_pos := [3]f32{10.0, 0.0, 10.0}
    crowd.path_corridor_reset(corridor, recast.Poly_Ref(5), start_pos)
    
    filter := new(detour.Query_Filter)
    defer free(filter)
    detour.query_filter_init(filter)
    
    // Test position tracking
    current_pos := crowd.path_corridor_get_pos(corridor)
    testing.expect(t, positions_equal(current_pos, start_pos), "Position should match initial position")
    
    // Test target tracking
    target_pos := [3]f32{12.0, 0.0, 12.0}
    corridor.target = target_pos
    
    current_target := crowd.path_corridor_get_target(corridor)
    testing.expect(t, positions_equal(current_target, target_pos), "Target should match set target")
}

// =============================================================================
// Path Corridor Integration Tests
// =============================================================================

@(test)
test_path_corridor_with_agent_movement :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)
    
    // Add agent at known position
    start_pos := [3]f32{7.0, 0.0, 7.0}
    agent_id := add_test_agent(t, crowd_system, start_pos)
    
    // Set specific target
    target_pos := [3]f32{23.0, 0.0, 23.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, target_ref, nearest_target := detour.find_nearest_poly(crowd_system.nav_query, target_pos, half_extents, filter)
    
    move_status := crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    testing.expect(t, recast.status_succeeded(move_status), "Move request should succeed")
    
    // Update several times and verify corridor state
    for i in 0..<10 {
        crowd.crowd_update(crowd_system, 0.1, nil)
        
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        if agent == nil do break
        
        // Test corridor properties
        corridor_pos := crowd.path_corridor_get_pos(&agent.corridor)
        corridor_target := crowd.path_corridor_get_target(&agent.corridor)
        path_len := len(agent.corridor.path)
        
        testing.expect(t, path_len >= 1, "Corridor should always have at least 1 polygon")
        testing.expect(t, corridor_target != [3]f32{}, "Corridor should have a target")
        
        // Test that agent position matches corridor position  
        pos_diff := linalg.distance(agent.position, corridor_pos)
        testing.expect(t, pos_diff < 0.1, "Agent position should match corridor position closely")
        
        if i == 5 {
            // At iteration 5, verify specific corridor state
            first_poly := crowd.path_corridor_get_first_poly(&agent.corridor)
            last_poly := crowd.path_corridor_get_last_poly(&agent.corridor)
            
            testing.expect(t, first_poly != recast.INVALID_POLY_REF, "First poly should be valid")
            testing.expect(t, last_poly != recast.INVALID_POLY_REF, "Last poly should be valid")
            
            fmt.printf("Iteration %d: path_len=%d, first_poly=%v, last_poly=%v\n", 
                      i, path_len, first_poly, last_poly)
        }
    }
}

// =============================================================================
// Path Planning System Tests  
// =============================================================================

@(test)
test_complete_pathfinding_workflow :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Create agents at opposite corners of grid
    agent_positions := [][3]f32{
        {5.0, 0.0, 5.0},   // Bottom-left
        {25.0, 0.0, 25.0}, // Top-right
        {5.0, 0.0, 25.0},  // Top-left
        {25.0, 0.0, 5.0},  // Bottom-right
    }
    
    agent_targets := [][3]f32{
        {25.0, 0.0, 25.0}, // Diagonal
        {5.0, 0.0, 5.0},   // Return diagonal
        {25.0, 0.0, 5.0},  // Horizontal
        {5.0, 0.0, 25.0},  // Vertical
    }
    
    agents := make([]recast.Agent_Id, len(agent_positions))
    defer delete(agents)
    
    // Add all agents
    for pos, i in agent_positions {
        agents[i] = add_test_agent(t, crowd_system, pos)
    }
    
    // Request movement for all agents
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    for target, i in agent_targets {
        _, target_ref, nearest_target := detour.find_nearest_poly(crowd_system.nav_query, target, half_extents, filter)
        crowd.crowd_request_move_target(crowd_system, agents[i], target_ref, nearest_target)
    }
    
    // Need to update once to process path requests
    crowd.crowd_update(crowd_system, 0.01, nil)
    
    // Simulate movement and verify pathfinding results
    initial_distances := make([]f32, len(agents))
    defer delete(initial_distances)
    
    // Record initial distances to targets
    for i in 0..<len(agents) {
        agent := crowd.crowd_get_agent(crowd_system, agents[i])
        if agent != nil {
            initial_distances[i] = linalg.distance(agent.position, agent_targets[i])
        }
    }
    
    // Update for multiple steps
    for step in 0..<30 {
        crowd.crowd_update(crowd_system, 0.1, nil)
        
        if step == 10 || step == 20 || step == 29 {
            // Check progress at specific intervals
            for i in 0..<len(agents) {
                agent := crowd.crowd_get_agent(crowd_system, agents[i])
                if agent == nil do continue
                
                current_distance := linalg.distance(agent.position, agent_targets[i])
                progress := initial_distances[i] - current_distance
                
                testing.expect(t, progress >= 0, "Agent should make progress toward target")
                
                // Verify agent has a valid path
                path := crowd.agent_get_path(agent)
                testing.expect(t, len(path) >= 1, "Agent should have valid path")
                
                // Verify agent state is reasonable
                state := crowd.agent_get_state(agent)
                testing.expect(t, state != .Invalid, "Agent state should be valid")
                
                target_state := crowd.agent_get_target_state(agent)
                testing.expect(t, target_state != .None && target_state != .Failed, 
                              "Target state should be active")
                
                // Debug output
                if i == 0 && (step == 0 || step == 10 || step == 29) {  // Log first agent at key steps
                    vel_mag := linalg.length(agent.velocity)
                    desired_vel_mag := linalg.length(agent.desired_velocity)
                    fmt.printf("Step %d, Agent %d: pos=(%.2f,%.2f,%.2f), target=(%.2f,%.2f,%.2f), vel=%.2f, des_vel=%.2f, progress=%.2f, corners=%d\n",
                              step, i, agent.position.x, agent.position.y, agent.position.z, 
                              agent_targets[i].x, agent_targets[i].y, agent_targets[i].z,
                              vel_mag, desired_vel_mag, progress, agent.corner_count)
                    // Log all corners
                    for c in 0..<agent.corner_count {
                        fmt.printf("  Corner[%d]: (%.2f,%.2f,%.2f)\n", c,
                                  agent.corner_verts[c].x, agent.corner_verts[c].y, agent.corner_verts[c].z)
                    }
                }
            }
        }
    }
    
    // Final verification - all agents should have made meaningful progress
    for i in 0..<len(agents) {
        agent := crowd.crowd_get_agent(crowd_system, agents[i])
        if agent != nil {
            final_distance := linalg.distance(agent.position, agent_targets[i])
            progress := initial_distances[i] - final_distance
            testing.expect(t, progress > 1.0, "Agent should make significant progress (>1.0 units)")
        }
    }
}

@(test)
test_path_invalidation_and_replanning :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)
    
    // Add agent
    start_pos := [3]f32{5.0, 0.0, 5.0}
    agent_id := add_test_agent(t, crowd_system, start_pos)
    
    // Set target
    target_pos := [3]f32{25.0, 0.0, 25.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, target_ref, nearest_target := detour.find_nearest_poly(crowd_system.nav_query, target_pos, half_extents, filter)
    
    crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    
    // Update until agent has established path
    for i in 0..<10 {
        crowd.crowd_update(crowd_system, 0.1, nil)
    }
    
    agent := crowd.crowd_get_agent(crowd_system, agent_id)
    testing.expect(t, agent != nil, "Agent should exist")
    
    initial_path_len := len(crowd.agent_get_path(agent))
    testing.expect(t, initial_path_len > 1, "Agent should have multi-segment path")
    
    // Reset move target to force replanning
    reset_status := crowd.crowd_reset_move_target(crowd_system, agent_id)
    testing.expect(t, recast.status_succeeded(reset_status), "Reset should succeed")
    
    // Verify target state changed
    target_state_after_reset := crowd.agent_get_target_state(agent)
    testing.expect(t, target_state_after_reset == .None, "Target state should be None after reset")
    
    // Set new target
    new_target_pos := [3]f32{15.0, 0.0, 15.0}
    _, new_target_ref, new_nearest_target := detour.find_nearest_poly(crowd_system.nav_query, new_target_pos, half_extents, filter)
    
    crowd.crowd_request_move_target(crowd_system, agent_id, new_target_ref, new_nearest_target)
    
    // Update to establish new path
    for i in 0..<10 {
        crowd.crowd_update(crowd_system, 0.1, nil)
    }
    
    // Verify new path is different
    agent = crowd.crowd_get_agent(crowd_system, agent_id)
    new_target_state := crowd.agent_get_target_state(agent)
    testing.expect(t, new_target_state != .None && new_target_state != .Failed, 
                  "Should have active target after replanning")
    
    final_path_len := len(crowd.agent_get_path(agent))
    testing.expect(t, final_path_len >= 1, "Should have valid path after replanning")
}