package test_detour_crowd

import "core:testing"
import "core:time"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

// Test single agent pathfinding to target
@(test)
test_single_agent_pathfinding :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Add single agent
    start_pos := [3]f32{5, 0, 5}
    agent_id := add_test_agent(t, crowd_system, start_pos)
    
    // Verify agent was added
    agent := crowd.crowd_get_agent(crowd_system, agent_id)
    testing.expect(t, agent != nil, "Agent should not be nil")
    testing.expect(t, agent.active, "Agent should be active")
    testing.expect(t, positions_equal(agent.position, start_pos), "Agent should be at start position")
    
    // Request move to target
    target_pos := [3]f32{25, 0, 25}
    half_extents := [3]f32{2, 2, 2}
    
    // Find nearest polygon to target
    filter := crowd.crowd_get_filter(crowd_system, 0)
    testing.expect(t, filter != nil, "Filter should not be nil")
    
    find_status, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )
    testing.expect(t, recast.status_succeeded(find_status), "Should find target polygon")
    testing.expect(t, target_ref != recast.INVALID_POLY_REF, "Target ref should be valid")
    
    move_status := crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    testing.expect(t, recast.status_succeeded(move_status), "Move request should succeed")
    
    // Update crowd and check progress
    max_frames := 100
    dt := f32(0.1)
    
    for frame in 0..<max_frames {
        update_status := crowd.crowd_update(crowd_system, dt, nil)
        testing.expect(t, recast.status_succeeded(update_status), "Update should succeed")
        
        agent = crowd.crowd_get_agent(crowd_system, agent_id)
        if agent == nil do break
        
        // Check if agent is moving
        if frame > 5 && linalg.length(agent.velocity) < 0.01 {
            // Agent stopped moving
            if agent_reached_target(agent, nearest_target) {
                fmt.printf( "Agent reached target after %d frames", frame)
                break
            } else {
                fmt.printf( "Agent stopped before reaching target at frame %d", frame)
                fmt.printf( "Position: (%.2f, %.2f, %.2f), Target: (%.2f, %.2f, %.2f)",
                            agent.position.x, agent.position.y, agent.position.z,
                            nearest_target.x, nearest_target.y, nearest_target.z)
            }
        }
        
        // Log progress every 10 frames
        if frame % 10 == 0 {
            fmt.printf( "Frame %d: pos=(%.2f,%.2f,%.2f), vel=(%.2f,%.2f,%.2f), state=%v, targetState=%v, corners=%d",
                        frame, agent.position.x, agent.position.y, agent.position.z,
                        agent.velocity.x, agent.velocity.y, agent.velocity.z,
                        agent.state, agent.target_state, agent.corner_count)
            if agent.corner_count > 0 {
                fmt.printf(" next_corner=(%.2f,%.2f,%.2f)", 
                          agent.corner_verts[0].x, agent.corner_verts[0].y, agent.corner_verts[0].z)
            }
            fmt.printf("\n")
        }
    }
    
    // Verify agent made progress toward target
    final_agent := crowd.crowd_get_agent(crowd_system, agent_id)
    if final_agent != nil {
        initial_dist := linalg.distance(start_pos, nearest_target)
        final_dist := linalg.distance(final_agent.position, nearest_target)
        testing.expect(t, final_dist < initial_dist, "Agent should move closer to target")
    }
}

// Test multiple agents avoiding each other
@(test)
test_multiple_agents_collision_avoidance :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Add multiple agents in a line
    agent_ids: [dynamic]recast.Agent_Id
    defer delete(agent_ids)
    
    for i in 0..<4 {
        pos := [3]f32{5 + f32(i) * 2, 0, 5}
        agent_id := add_test_agent(t, crowd_system, pos)
        append(&agent_ids, agent_id)
    }
    
    // Set common target for all agents
    target_pos := [3]f32{15, 0, 15}
    half_extents := [3]f32{2, 2, 2}
    
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )
    
    for agent_id in agent_ids {
        crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    }
    
    // Update and check for collisions
    dt := f32(0.1)
    min_separation := f32(0.5)  // Minimum separation between agents
    
    for frame in 0..<50 {
        crowd.crowd_update(crowd_system, dt, nil)
        
        // Check agent separations
        for i in 0..<len(agent_ids) {
            agent_i := crowd.crowd_get_agent(crowd_system, agent_ids[i])
            if agent_i == nil || !agent_i.active do continue
            
            for j in i+1..<len(agent_ids) {
                agent_j := crowd.crowd_get_agent(crowd_system, agent_ids[j])
                if agent_j == nil || !agent_j.active do continue
                
                dist := linalg.distance(agent_i.position, agent_j.position)
                
                // Agents should maintain minimum separation
                if dist < min_separation {
                    fmt.printf( "Warning: Agents %d and %d too close at frame %d: %.3f",
                                i, j, frame, dist)
                }
            }
            
            // Log neighbor count
            if frame % 10 == 0 && i == 0 {
                fmt.printf( "Frame %d: Agent 0 has %d neighbors",
                            frame, agent_i.neighbor_count)
            }
        }
    }
    
    // Verify all agents made progress
    for agent_id, i in agent_ids {
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        if agent != nil {
            start_pos := [3]f32{5 + f32(i) * 2, 0, 5}
            initial_dist := linalg.distance(start_pos, nearest_target)
            final_dist := linalg.distance(agent.position, nearest_target)
            testing.expect(t, final_dist < initial_dist,
                          "Agent should move closer to target")
        }
    }
}

// Test agent velocity control
@(test)
test_agent_velocity_control :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Add agent
    start_pos := [3]f32{15, 0, 15}
    agent_id := add_test_agent(t, crowd_system, start_pos)
    
    // Request velocity movement
    desired_vel := [3]f32{1, 0, 0}  // Move right
    vel_status := crowd.crowd_request_move_velocity(crowd_system, agent_id, desired_vel)
    testing.expect(t, recast.status_succeeded(vel_status), "Velocity request should succeed")
    
    // Update and check velocity
    dt := f32(0.1)
    for frame in 0..<20 {
        crowd.crowd_update(crowd_system, dt, nil)
        
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        if agent == nil do break
        
        if frame > 5 {
            // After a few frames, velocity should align with desired
            vel_mag := linalg.length(agent.velocity)
            if vel_mag > 0.1 {
                vel_dir := agent.velocity / vel_mag
                dot := linalg.dot(vel_dir, linalg.normalize(desired_vel))
                testing.expect(t, dot > 0.8, "Velocity should align with desired direction")
            }
        }
        
        if frame % 5 == 0 {
            fmt.printf( "Frame %d: vel=(%.2f,%.2f,%.2f), desired=(%.2f,%.2f,%.2f)",
                        frame, agent.velocity.x, agent.velocity.y, agent.velocity.z,
                        desired_vel.x, desired_vel.y, desired_vel.z)
        }
    }
}

// Test obstacle avoidance parameters
@(test)
test_obstacle_avoidance_parameters :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Set different obstacle avoidance parameters
    low_quality := crowd.obstacle_avoidance_params_create_low_quality()
    high_quality := crowd.obstacle_avoidance_params_create_high_quality()
    
    status1 := crowd.crowd_set_obstacle_avoidance_params(crowd_system, 0, &low_quality)
    testing.expect(t, recast.status_succeeded(status1), "Should set low quality params")
    
    status2 := crowd.crowd_set_obstacle_avoidance_params(crowd_system, 1, &high_quality)
    testing.expect(t, recast.status_succeeded(status2), "Should set high quality params")
    
    // Retrieve and verify parameters
    retrieved_low := crowd.crowd_get_obstacle_avoidance_params(crowd_system, 0)
    testing.expect(t, retrieved_low != nil, "Should retrieve low quality params")
    if retrieved_low != nil {
        testing.expect(t, retrieved_low.grid_size == low_quality.grid_size,
                      "Grid size should match")
    }
    
    retrieved_high := crowd.crowd_get_obstacle_avoidance_params(crowd_system, 1)
    testing.expect(t, retrieved_high != nil, "Should retrieve high quality params")
    if retrieved_high != nil {
        testing.expect(t, retrieved_high.grid_size == high_quality.grid_size,
                      "Grid size should match")
        testing.expect(t, retrieved_high.grid_size > retrieved_low.grid_size,
                      "High quality should have larger grid")
    }
    
    // Add agents with different avoidance types
    params_low := crowd.agent_params_create_default()
    params_low.obstacle_avoidance_type = 0
    
    params_high := crowd.agent_params_create_default()
    params_high.obstacle_avoidance_type = 1
    
    pos1 := [3]f32{5, 0, 5}
    pos2 := [3]f32{10, 0, 10}
    
    agent1, _ := crowd.crowd_add_agent(crowd_system, pos1, &params_low)
    agent2, _ := crowd.crowd_add_agent(crowd_system, pos2, &params_high)
    
    // Update and verify agents use different parameters
    crowd.crowd_update(crowd_system, 0.1, nil)
    
    a1 := crowd.crowd_get_agent(crowd_system, agent1)
    a2 := crowd.crowd_get_agent(crowd_system, agent2)
    
    if a1 != nil && a2 != nil {
        testing.expect(t, a1.params.obstacle_avoidance_type == 0,
                      "Agent 1 should use type 0")
        testing.expect(t, a2.params.obstacle_avoidance_type == 1,
                      "Agent 2 should use type 1")
    }
}

// Test path corridor operations
@(test)
test_path_corridor_operations :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Add agent
    start_pos := [3]f32{5, 0, 5}
    agent_id := add_test_agent(t, crowd_system, start_pos)
    
    // Request path to far target
    target_pos := [3]f32{25, 0, 25}
    half_extents := [3]f32{2, 2, 2}
    
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )
    
    crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    
    // Update a few times to establish path
    for i in 0..<10 {
        crowd.crowd_update(crowd_system, 0.1, nil)
    }
    
    // Check agent's path
    agent := crowd.crowd_get_agent(crowd_system, agent_id)
    if agent != nil {
        // Check corners
        corner_count := crowd.agent_get_corner_count(agent)
        testing.expect(t, corner_count > 0, "Agent should have corners in path")
        
        for i in 0..<min(corner_count, 3) {
            pos, flags, poly, found := crowd.agent_get_corner(agent, i)
            if found {
                fmt.printf( "Corner %d: pos=(%.2f,%.2f,%.2f), flags=%d, poly=%v",
                            i, pos.x, pos.y, pos.z, flags, poly)
            }
        }
        
        // Check path
        path := crowd.agent_get_path(agent)
        testing.expect(t, len(path) > 0, "Agent should have path")
        fmt.printf( "Path length: %d polygons", len(path))
        
        // Check boundary segments
        seg_count := crowd.agent_get_boundary_segment_count(agent)
        fmt.printf( "Boundary segment count: %d", seg_count)
    }
}

// Test agent state transitions
@(test)
test_agent_state_transitions :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Add agent
    start_pos := [3]f32{5, 0, 5}
    agent_id := add_test_agent(t, crowd_system, start_pos)
    
    agent := crowd.crowd_get_agent(crowd_system, agent_id)
    testing.expect(t, agent != nil, "Agent should exist")
    
    // Check initial state
    initial_state := crowd.agent_get_state(agent)
    testing.expect(t, initial_state == .Walking, "Initial state should be Walking")
    
    // Check target state transitions
    initial_target_state := crowd.agent_get_target_state(agent)
    testing.expect(t, initial_target_state == .None, "Initial target state should be None")
    
    // Request move
    target_pos := [3]f32{15, 0, 15}
    half_extents := [3]f32{2, 2, 2}
    
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )
    
    crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    
    // Check state after request
    agent = crowd.crowd_get_agent(crowd_system, agent_id)
    request_target_state := crowd.agent_get_target_state(agent)
    fmt.printf( "Target state after request: %v", request_target_state)
    
    // Update and monitor state changes
    for i in 0..<20 {
        crowd.crowd_update(crowd_system, 0.1, nil)
        
        agent = crowd.crowd_get_agent(crowd_system, agent_id)
        if agent == nil do break
        
        state := crowd.agent_get_state(agent)
        target_state := crowd.agent_get_target_state(agent)
        
        if i % 5 == 0 {
            fmt.printf( "Frame %d: state=%v, target_state=%v",
                        i, state, target_state)
        }
    }
}