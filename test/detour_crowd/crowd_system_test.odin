package test_detour_crowd

import "core:testing"
import "core:time"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

// Test evacuation scenario - all agents move to single exit
@(test)
test_evacuation_scenario :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 60 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd with more agents
    crowd_system := create_test_crowd(t, nav_mesh, 20)
    defer destroy_test_crowd(crowd_system)
    
    // Add agents in random positions
    agent_ids: [dynamic]recast.Agent_Id
    defer delete(agent_ids)
    
    for i in 0..<10 {
        // Random position in the grid
        x := 5 + f32(i * 2)
        z := 5 + f32(i * 2)
        pos := [3]f32{x, 0, z}
        
        agent_id := add_test_agent(t, crowd_system, pos)
        append(&agent_ids, agent_id)
    }
    
    // Set exit point as target for all agents
    exit_pos := [3]f32{28, 0, 28}  // Corner of the grid
    half_extents := [3]f32{2, 2, 2}
    
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, exit_ref, nearest_exit := detour.find_nearest_poly(
        crowd_system.nav_query, exit_pos, half_extents, filter
    )
    
    // All agents target the exit
    for agent_id in agent_ids {
        crowd.crowd_request_move_target(crowd_system, agent_id, exit_ref, nearest_exit)
    }
    
    // Simulate evacuation
    dt := f32(0.1)
    max_frames := 200
    agents_at_exit := 0
    exit_threshold := f32(2.0)
    
    for frame in 0..<max_frames {
        crowd.crowd_update(crowd_system, dt, nil)
        
        // Count agents that reached exit
        current_at_exit := 0
        for agent_id in agent_ids {
            agent := crowd.crowd_get_agent(crowd_system, agent_id)
            if agent != nil && agent.active {
                dist := linalg.distance(agent.position, nearest_exit)
                if dist < exit_threshold {
                    current_at_exit += 1
                }
            }
        }
        
        if current_at_exit > agents_at_exit {
            agents_at_exit = current_at_exit
            fmt.printf( "Frame %d: %d agents reached exit", frame, agents_at_exit)
        }
        
        // Check if all evacuated
        if agents_at_exit >= len(agent_ids) {
            fmt.printf( "All agents evacuated in %d frames", frame)
            break
        }
        
        // Log crowd statistics periodically
        if frame % 20 == 0 {
            stats := crowd.crowd_get_statistics(crowd_system)
            fmt.printf( "Frame %d: active_agents=%d",
                        frame, stats.active_agents)
        }
    }
    
    testing.expect(t, agents_at_exit > len(agent_ids) / 2,
                  "At least half the agents should reach the exit")
}

// Test crowd flow through narrow passage
@(test)
test_narrow_passage_flow :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 60 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 20)
    defer destroy_test_crowd(crowd_system)
    
    // Add agents on one side trying to pass through middle
    agent_ids: [dynamic]recast.Agent_Id
    defer delete(agent_ids)
    
    // Create two groups of agents
    for i in 0..<6 {
        // Left group
        x := f32(5 + (i % 2) * 2)
        z := f32(10 + (i / 2) * 2)
        pos := [3]f32{x, 0, z}
        agent_id := add_test_agent(t, crowd_system, pos)
        append(&agent_ids, agent_id)
    }
    
    // All agents target the right side
    target_pos := [3]f32{25, 0, 15}
    half_extents := [3]f32{2, 2, 2}
    
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )
    
    for agent_id in agent_ids {
        crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    }
    
    // Simulate and check for congestion
    dt := f32(0.1)
    max_stalled_frames := 0
    
    for frame in 0..<100 {
        crowd.crowd_update(crowd_system, dt, nil)
        
        // Check agent velocities for congestion
        stalled_agents := 0
        for agent_id in agent_ids {
            agent := crowd.crowd_get_agent(crowd_system, agent_id)
            if agent != nil && agent.active {
                speed := linalg.length(agent.velocity)
                if speed < 0.5 {  // Agent is moving slowly
                    stalled_agents += 1
                }
            }
        }
        
        if stalled_agents > len(agent_ids) / 2 {
            max_stalled_frames += 1
        } else {
            max_stalled_frames = 0
        }
        
        if frame % 20 == 0 {
            fmt.printf( "Frame %d: %d agents stalled", frame, stalled_agents)
        }
    }
    
    testing.expect(t, max_stalled_frames < 20,
                  "Agents should not be permanently stalled")
}

// Test different agent types (sizes and speeds)
@(test)
test_heterogeneous_agents :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 60 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 20)
    defer destroy_test_crowd(crowd_system)
    
    // Create different agent types
    soldier_params := crowd.agent_params_create_soldier()
    civilian_params := crowd.agent_params_create_civilian()
    vehicle_params := crowd.agent_params_create_vehicle()
    
    // Add agents of each type
    soldier_id, _ := crowd.crowd_add_agent(crowd_system, {5, 0, 5}, &soldier_params)
    civilian_id, _ := crowd.crowd_add_agent(crowd_system, {10, 0, 10}, &civilian_params)
    vehicle_id, _ := crowd.crowd_add_agent(crowd_system, {15, 0, 15}, &vehicle_params)
    
    // Set common target
    target_pos := [3]f32{25, 0, 25}
    half_extents := [3]f32{2, 2, 2}
    
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )
    
    crowd.crowd_request_move_target(crowd_system, soldier_id, target_ref, nearest_target)
    crowd.crowd_request_move_target(crowd_system, civilian_id, target_ref, nearest_target)
    crowd.crowd_request_move_target(crowd_system, vehicle_id, target_ref, nearest_target)
    
    // Track agent speeds
    dt := f32(0.1)
    max_speeds := [3]f32{}
    
    for frame in 0..<50 {
        crowd.crowd_update(crowd_system, dt, nil)
        
        // Measure speeds
        soldier := crowd.crowd_get_agent(crowd_system, soldier_id)
        civilian := crowd.crowd_get_agent(crowd_system, civilian_id)
        vehicle := crowd.crowd_get_agent(crowd_system, vehicle_id)
        
        if soldier != nil {
            speed := linalg.length(soldier.velocity)
            max_speeds[0] = max(max_speeds[0], speed)
        }
        
        if civilian != nil {
            speed := linalg.length(civilian.velocity)
            max_speeds[1] = max(max_speeds[1], speed)
        }
        
        if vehicle != nil {
            speed := linalg.length(vehicle.velocity)
            max_speeds[2] = max(max_speeds[2], speed)
        }
        
        if frame % 10 == 0 {
            fmt.printf( "Frame %d: soldier=%.2f, civilian=%.2f, vehicle=%.2f",
                        frame, max_speeds[0], max_speeds[1], max_speeds[2])
        }
    }
    
    // Verify different agent types have different characteristics
    testing.expect(t, max_speeds[2] > max_speeds[1],
                  "Vehicle should be faster than civilian")
    
    // Check agent parameters
    soldier := crowd.crowd_get_agent(crowd_system, soldier_id)
    civilian := crowd.crowd_get_agent(crowd_system, civilian_id)
    vehicle := crowd.crowd_get_agent(crowd_system, vehicle_id)
    
    if soldier != nil && civilian != nil && vehicle != nil {
        testing.expect(t, vehicle.params.radius > soldier.params.radius,
                      "Vehicle should be larger than soldier")
        testing.expect(t, vehicle.params.max_speed > civilian.params.max_speed,
                      "Vehicle should have higher max speed than civilian")
    }
}

// Test performance with many agents
@(test)
test_crowd_performance :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 60 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd with maximum agents
    max_agents := i32(50)
    crowd_system := create_test_crowd(t, nav_mesh, max_agents)
    defer destroy_test_crowd(crowd_system)
    
    // Add many agents
    agent_ids: [dynamic]recast.Agent_Id
    defer delete(agent_ids)
    
    for i in 0..<int(max_agents) {
        x := 2 + f32(i % 10) * 2.6
        z := 2 + f32(i / 10) * 2.6
        pos := [3]f32{x, 0, z}
        
        params := crowd.agent_params_create_default()
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        
        if recast.status_succeeded(status) {
            append(&agent_ids, agent_id)
        }
    }
    
    fmt.printf( "Added %d agents", len(agent_ids))
    
    // Give random targets to create movement
    filter := crowd.crowd_get_filter(crowd_system, 0)
    half_extents := [3]f32{2, 2, 2}
    
    for agent_id, i in agent_ids {
        x := 2 + f32(i % 10) * 2.6
        z := 2 + f32(i / 10) * 2.6
        target_pos := [3]f32{x, 0, z}
        
        _, target_ref, nearest_target := detour.find_nearest_poly(
            crowd_system.nav_query, target_pos, half_extents, filter
        )
        
        if target_ref != recast.INVALID_POLY_REF {
            crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
        }
    }
    
    // Measure update performance
    dt := f32(0.033)  // ~30 FPS
    start_time := time.now()
    
    for frame in 0..<30 {
        crowd.crowd_update(crowd_system, dt, nil)
    }
    
    elapsed := time.since(start_time)
    avg_frame_time := time.duration_milliseconds(elapsed) / 30.0
    
    fmt.printf( "Average frame time with %d agents: %.2f ms",
                len(agent_ids), avg_frame_time)
    
    // Check performance is reasonable
    testing.expect(t, avg_frame_time < 100,
                  "Frame time should be under 100ms for real-time performance")
    
    // Get final statistics
    stats := crowd.crowd_get_statistics(crowd_system)
    fmt.printf( "Final stats: active=%d, max=%d",
                stats.active_agents, stats.max_agents)
}

// Test path replanning when blocked
@(test)
test_path_replanning :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 60 * time.Second)
    
    // Create navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Create crowd
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Add main agent
    main_pos := [3]f32{5, 0, 5}
    main_id := add_test_agent(t, crowd_system, main_pos)
    
    // Add blocking agents in the path
    for i in 0..<3 {
        block_pos := [3]f32{10 + f32(i), 0, 10}
        params := crowd.agent_params_create_default()
        params.max_speed = 0  // Stationary blockers
        crowd.crowd_add_agent(crowd_system, block_pos, &params)
    }
    
    // Main agent tries to reach target
    target_pos := [3]f32{15, 0, 15}
    half_extents := [3]f32{2, 2, 2}
    
    filter := crowd.crowd_get_filter(crowd_system, 0)
    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, target_pos, half_extents, filter
    )
    
    crowd.crowd_request_move_target(crowd_system, main_id, target_ref, nearest_target)
    
    // Simulate and check for replanning
    dt := f32(0.1)
    last_pos := main_pos
    stuck_frames := 0
    
    for frame in 0..<100 {
        crowd.crowd_update(crowd_system, dt, nil)
        
        agent := crowd.crowd_get_agent(crowd_system, main_id)
        if agent == nil do break
        
        // Check if agent is stuck
        moved := linalg.distance(agent.position, last_pos)
        if moved < 0.01 {
            stuck_frames += 1
        } else {
            stuck_frames = 0
            last_pos = agent.position
        }
        
        if frame % 20 == 0 {
            fmt.printf( "Frame %d: pos=(%.2f,%.2f,%.2f), stuck=%d frames",
                        frame, agent.position.x, agent.position.y, agent.position.z,
                        stuck_frames)
        }
        
        // Agent should find alternative path or push through
        if stuck_frames > 30 {
            fmt.printf( "Agent appears stuck for too long")
            break
        }
    }
    
    // Check final progress
    final_agent := crowd.crowd_get_agent(crowd_system, main_id)
    if final_agent != nil {
        final_dist := linalg.distance(final_agent.position, nearest_target)
        initial_dist := linalg.distance(main_pos, nearest_target)
        
        testing.expect(t, final_dist < initial_dist * 0.5,
                      "Agent should make significant progress despite obstacles")
    }
}