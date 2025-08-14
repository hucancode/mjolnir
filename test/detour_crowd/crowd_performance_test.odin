package test_detour_crowd

import "core:testing"
import "core:time"
import "core:math"
import "core:math/linalg"
import "core:fmt"
import "core:math/rand"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

// =============================================================================
// Large Scale Crowd Tests
// =============================================================================

@(test)
test_large_crowd_basic_performance :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Test with 100 agents - large scale but manageable for testing
    max_agents := i32(100)
    crowd_system := create_test_crowd(t, nav_mesh, max_agents)
    defer destroy_test_crowd(crowd_system)
    
    // Add agents in a grid pattern
    grid_size := i32(10)  // 10x10 grid
    agents := make([]recast.Agent_Id, max_agents)
    defer delete(agents)
    
    start_time := time.now()
    
    agent_count := i32(0)
    params := crowd.agent_params_create_default()
    
    for x in 0..<grid_size {
        for z in 0..<grid_size {
            if agent_count >= max_agents do break
            
            pos := [3]f32{
                f32(5 + x * 2),  // Spread agents across nav mesh
                0.0,
                f32(5 + z * 2),
            }
            
            agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
            testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add agent %d", agent_count))
            
            agents[agent_count] = agent_id
            agent_count += 1
        }
    }
    
    creation_time := time.duration_milliseconds(time.since(start_time))
    testing.expect(t, agent_count == max_agents, fmt.tprintf("Should create exactly %d agents", max_agents))
    
    fmt.printf("Created %d agents in %.2f ms (%.2f ms per agent)\n", 
              agent_count, f64(creation_time), f64(creation_time) / f64(agent_count))
    
    // Set targets for all agents (convergence pattern)
    center_target := [3]f32{15.0, 0.0, 15.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, center_target, half_extents, filter
    )
    
    target_start_time := time.now()
    
    for agent_id in agents {
        status := crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
        testing.expect(t, recast.status_succeeded(status), "Should set target for agent")
    }
    
    target_time := time.duration_milliseconds(time.since(target_start_time))
    fmt.printf("Set targets for %d agents in %.2f ms\n", agent_count, f64(target_time))
    
    // Performance test: measure update times
    update_times := make([dynamic]f64, 0, 30)
    defer delete(update_times)
    
    for frame in 0..<30 {
        frame_start := time.now()
        
        status := crowd.crowd_update(crowd_system, 0.1, nil)
        testing.expect(t, recast.status_succeeded(status), "Crowd update should succeed")
        
        frame_time := time.duration_microseconds(time.since(frame_start))
        append(&update_times, f64(frame_time) / 1000.0)  // Convert to milliseconds
        
        if frame % 5 == 0 {
            active_count := crowd.crowd_get_active_agent_count(crowd_system)
            fmt.printf("Frame %d: %.2f ms, %d active agents\n", frame, update_times[frame], active_count)
        }
    }
    
    // Calculate performance statistics
    total_time := f64(0)
    min_time := math.F64_MAX
    max_time := f64(0)
    
    for update_time in update_times {
        total_time += update_time
        min_time = min(min_time, update_time)
        max_time = max(max_time, update_time)
    }
    
    avg_time := total_time / f64(len(update_times))
    
    fmt.printf("Performance with %d agents over %d frames:\n", agent_count, len(update_times))
    fmt.printf("  Average: %.2f ms per update\n", avg_time)
    fmt.printf("  Min: %.2f ms\n", min_time)
    fmt.printf("  Max: %.2f ms\n", max_time)
    fmt.printf("  Per agent: %.4f ms\n", avg_time / f64(agent_count))
    
    // Verify reasonable performance (this is implementation dependent)
    testing.expect(t, avg_time < 100.0, "Average update time should be reasonable")
    testing.expect(t, max_time < 500.0, "Max update time should not be excessive")
    
    // Verify all agents remain active
    final_active_count := crowd.crowd_get_active_agent_count(crowd_system)
    testing.expect(t, final_active_count == max_agents, "All agents should remain active")
}

@(test)
test_bidirectional_flow_stress :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Test with agents flowing in opposite directions
    agent_count := i32(40)  // Manageable count for stress test
    crowd_system := create_test_crowd(t, nav_mesh, agent_count)
    defer destroy_test_crowd(crowd_system)
    
    // Create two groups moving in opposite directions
    group_size := agent_count / 2
    
    group_a_agents := make([]recast.Agent_Id, group_size)
    group_b_agents := make([]recast.Agent_Id, group_size)
    defer delete(group_a_agents)
    defer delete(group_b_agents)
    
    params := crowd.agent_params_create_default()
    params.separation_weight = 2.5  // Higher separation for stress test
    
    // Group A: Start at left, move right
    for i in 0..<group_size {
        pos := [3]f32{
            7.0,
            0.0,
            f32(10 + i),  // Spread vertically
        }
        
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add group A agent %d", i))
        group_a_agents[i] = agent_id
    }
    
    // Group B: Start at right, move left
    for i in 0..<group_size {
        pos := [3]f32{
            23.0,
            0.0,
            f32(10 + i),  // Spread vertically
        }
        
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add group B agent %d", i))
        group_b_agents[i] = agent_id
    }
    
    // Set opposite targets
    target_a := [3]f32{23.0, 0.0, 15.0}  // Group A moves right
    target_b := [3]f32{7.0, 0.0, 15.0}   // Group B moves left
    
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    _, target_ref_a, nearest_target_a := detour.find_nearest_poly(
        crowd_system.nav_query, target_a, half_extents, filter
    )
    
    _, target_ref_b, nearest_target_b := detour.find_nearest_poly(
        crowd_system.nav_query, target_b, half_extents, filter
    )
    
    // Set targets for both groups
    for agent_id, i in group_a_agents {
        status := crowd.crowd_request_move_target(crowd_system, agent_id, target_ref_a, nearest_target_a)
        if recast.status_failed(status) {
            fmt.printf("Failed to set target for Group A agent %d: status=%v\n", i, status)
        }
    }
    
    for agent_id, i in group_b_agents {
        status := crowd.crowd_request_move_target(crowd_system, agent_id, target_ref_b, nearest_target_b)
        if recast.status_failed(status) {
            fmt.printf("Failed to set target for Group B agent %d: status=%v\n", i, status)
        }
    }
    
    // Monitor collision metrics during bidirectional flow
    collision_count := 0
    min_separation := f32(999.0)
    total_separation := f32(0.0)
    separation_samples := 0
    
    for frame in 0..<80 {  // Increased simulation time for agents to make more progress
        crowd.crowd_update(crowd_system, 0.1, nil)
        
        // Check separations between all agent pairs
        for i in 0..<len(group_a_agents) {
            agent_a := crowd.crowd_get_agent(crowd_system, group_a_agents[i])
            if agent_a == nil do continue
            
            for j in 0..<len(group_b_agents) {
                agent_b := crowd.crowd_get_agent(crowd_system, group_b_agents[j])
                if agent_b == nil do continue
                
                distance := linalg.distance(agent_a.position, agent_b.position)
                min_separation = min(min_separation, distance)
                total_separation += distance
                separation_samples += 1
                
                // Count potential collisions (agents too close)
                if distance < 0.8 {  // Less than combined radius
                    collision_count += 1
                }
            }
        }
        
        if frame % 10 == 0 {
            avg_sep := total_separation / f32(separation_samples) if separation_samples > 0 else 0.0
            fmt.printf("Frame %d: min_sep=%.3f, avg_sep=%.3f, collisions=%d\n",
                      frame, min_separation, avg_sep, collision_count)
        }
    }
    
    // Evaluate stress test results
    fmt.printf("Bidirectional flow results:\n")
    fmt.printf("  Total collision events: %d\n", collision_count)
    fmt.printf("  Minimum separation: %.3f\n", min_separation)
    
    testing.expect(t, min_separation > 0.2, "Agents should maintain minimum separation")
    testing.expect(t, collision_count < int(agent_count) * 10, "Collision count should be reasonable")
    
    // Verify agents made progress
    group_a_progress := 0
    group_b_progress := 0
    
    for agent_id in group_a_agents {
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        // Group A starts at x=7, target is x=23
        // Consider progress if moved at least 3 units right
        if agent != nil && agent.position.x > 10.0 {  // Moved at least 3 units right
            group_a_progress += 1
        }
    }
    
    for agent_id in group_b_agents {
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        if agent != nil {
            // Debug: check agent state - Group B starts at x=23, target is x=7
            // Consider progress if moved at least 3 units left
            if agent.position.x < 20.0 {  // Moved at least 3 units left
                group_b_progress += 1
            }
            // Log first agent's status for debugging
            if agent_id == group_b_agents[0] {
                fmt.printf("  First Group B agent: pos=(%.1f,%.1f,%.1f), target_state=%v, target_ref=0x%x, path_len=%d, target_path_ref=%d\n",
                          agent.position.x, agent.position.y, agent.position.z,
                          agent.target_state, agent.target_ref, len(agent.corridor.path), agent.target_path_ref)
            }
        }
    }
    
    testing.expect(t, group_a_progress > int(group_size) / 4, "Group A should make meaningful progress")
    testing.expect(t, group_b_progress > int(group_size) / 4, "Group B should make meaningful progress")
    
    fmt.printf("  Group A progress: %d/%d agents\n", group_a_progress, group_size)
    fmt.printf("  Group B progress: %d/%d agents\n", group_b_progress, group_size)
}

@(test)
test_formation_movement_performance :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    // Test formation movement with coordinated agents
    formation_size := i32(16)  // 4x4 formation
    crowd_system := create_test_crowd(t, nav_mesh, formation_size)
    defer destroy_test_crowd(crowd_system)
    
    // Create agents in tight formation
    formation_agents := make([]recast.Agent_Id, formation_size)
    defer delete(formation_agents)
    
    formation_center := [3]f32{10.0, 0.0, 10.0}
    agent_spacing := f32(1.2)  // Close formation
    
    params := crowd.agent_params_create_default()
    params.separation_weight = 1.0  // Lower separation to maintain formation
    params.max_speed = 2.0          // Consistent speed for formation
    
    side_count := i32(math.sqrt(f64(formation_size))) // Square formation
    
    agent_idx := 0
    for row in 0..<side_count {
        for col in 0..<side_count {
            if agent_idx >= int(formation_size) do break
            offset := [3]f32{
                (f32(col) - f32(side_count)/2) * agent_spacing,  // Center the formation
                0.0,
                (f32(row) - f32(side_count)/2) * agent_spacing,
            }
            
            pos := [3]f32{
                formation_center.x + offset.x,
                formation_center.y + offset.y,
                formation_center.z + offset.z,
            }
            
            agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
            testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add formation agent %d", agent_idx))
            formation_agents[agent_idx] = agent_id
            agent_idx += 1
        }
    }
    
    // Set formation target (move as a group)
    formation_target := [3]f32{20.0, 0.0, 20.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    _, target_ref, nearest_target := detour.find_nearest_poly(
        crowd_system.nav_query, formation_target, half_extents, filter
    )
    
    // All agents get the same target to maintain formation
    for agent_id in formation_agents {
        crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    }
    
    // Track formation cohesion over time
    initial_center := formation_center
    cohesion_history := make([dynamic]f32, 0, 25)
    defer delete(cohesion_history)
    
    for frame in 0..<40 {  // Increased simulation time for formation to make more progress
        start_time := time.now()
        crowd.crowd_update(crowd_system, 0.1, nil)
        update_time := time.duration_microseconds(time.since(start_time))
        
        // Calculate formation center and spread
        center := [3]f32{0, 0, 0}
        active_count := 0
        
        for agent_id in formation_agents {
            agent := crowd.crowd_get_agent(crowd_system, agent_id)
            if agent == nil do continue
            
            center += agent.position
            active_count += 1
        }
        
        if active_count > 0 {
            center /= f32(active_count)
            
            // Calculate formation cohesion (average distance from center)
            total_distance := f32(0.0)
            for agent_id in formation_agents {
                agent := crowd.crowd_get_agent(crowd_system, agent_id)
                if agent == nil do continue
                
                distance := linalg.distance(agent.position, center)
                total_distance += distance
            }
            
            cohesion := total_distance / f32(active_count)
            append(&cohesion_history, cohesion)
            
            if frame % 5 == 0 {
                progress := linalg.distance(initial_center, center)
                fmt.printf("Frame %d: cohesion=%.2f, progress=%.2f, update_time=%.2f ms\n",
                          frame, cohesion, progress, f64(update_time) / 1000.0)
            }
        }
    }
    
    // Evaluate formation performance
    if len(cohesion_history) > 0 {
        initial_cohesion := cohesion_history[0]
        final_cohesion := cohesion_history[len(cohesion_history) - 1]
        
        max_cohesion := f32(0.0)
        for cohesion in cohesion_history {
            max_cohesion = max(max_cohesion, cohesion)
        }
        
        fmt.printf("Formation movement results:\n")
        fmt.printf("  Initial cohesion: %.2f\n", initial_cohesion)
        fmt.printf("  Final cohesion: %.2f\n", final_cohesion)
        fmt.printf("  Max cohesion: %.2f\n", max_cohesion)
        
        // Formation should not spread too much
        testing.expect(t, max_cohesion < initial_cohesion * 3.0, 
                      "Formation should not spread excessively")
        
        // Formation should make progress
        final_center := [3]f32{0, 0, 0}
        active_count := 0
        
        for agent_id in formation_agents {
            agent := crowd.crowd_get_agent(crowd_system, agent_id)
            if agent == nil do continue
            
            final_center += agent.position
            active_count += 1
        }
        
        if active_count > 0 {
            final_center /= f32(active_count)
            progress := linalg.distance(initial_center, final_center)
            testing.expect(t, progress > 3.0, "Formation should make meaningful progress")
        }
    }
}

// =============================================================================
// Memory and Resource Stress Tests
// =============================================================================

@(test)
test_agent_churn_performance :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    max_concurrent := i32(25)
    crowd_system := create_test_crowd(t, nav_mesh, max_concurrent)
    defer destroy_test_crowd(crowd_system)
    
    // Test rapid agent addition/removal (churn)
    churn_cycles := 50
    agents_per_cycle := 5
    
    params := crowd.agent_params_create_default()
    
    // Use default random for simplicity - remove determinism for testing
    // rand.set_global_seed(12345)  // Deterministic for testing
    
    add_times := make([dynamic]f64, 0, churn_cycles * agents_per_cycle)
    remove_times := make([dynamic]f64, 0, churn_cycles * agents_per_cycle)
    defer delete(add_times)
    defer delete(remove_times)
    
    for cycle in 0..<churn_cycles {
        cycle_agents := make([]recast.Agent_Id, agents_per_cycle)
        defer delete(cycle_agents)
        
        // Add agents
        for i in 0..<agents_per_cycle {
            pos := [3]f32{
                rand.float32_range(5.0, 25.0),
                0.0,
                rand.float32_range(5.0, 25.0),
            }
            
            add_start := time.now()
            agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
            add_time := f64(time.duration_microseconds(time.since(add_start))) / 1000.0
            
            testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add agent in cycle %d", cycle))
            cycle_agents[i] = agent_id
            append(&add_times, add_time)
        }
        
        // Brief update
        crowd.crowd_update(crowd_system, 0.05, nil)
        
        // Remove agents
        for i in 0..<agents_per_cycle {
            remove_start := time.now()
            status := crowd.crowd_remove_agent(crowd_system, cycle_agents[i])
            remove_time := f64(time.duration_microseconds(time.since(remove_start))) / 1000.0
            
            testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should remove agent in cycle %d", cycle))
            append(&remove_times, remove_time)
        }
        
        if cycle % 10 == 0 {
            active_count := crowd.crowd_get_active_agent_count(crowd_system)
            fmt.printf("Churn cycle %d: %d active agents\n", cycle, active_count)
        }
    }
    
    // Calculate churn performance statistics
    total_add_time := f64(0.0)
    max_add_time := f64(0.0)
    total_remove_time := f64(0.0)
    max_remove_time := f64(0.0)
    
    for add_time in add_times {
        total_add_time += add_time
        max_add_time = max(max_add_time, add_time)
    }
    
    for remove_time in remove_times {
        total_remove_time += remove_time
        max_remove_time = max(max_remove_time, remove_time)
    }
    
    avg_add_time := total_add_time / f64(len(add_times))
    avg_remove_time := total_remove_time / f64(len(remove_times))
    
    fmt.printf("Agent churn performance (%d cycles, %d ops each):\n", 
              churn_cycles, agents_per_cycle)
    fmt.printf("  Add - Avg: %.3f ms, Max: %.3f ms\n", avg_add_time, max_add_time)
    fmt.printf("  Remove - Avg: %.3f ms, Max: %.3f ms\n", avg_remove_time, max_remove_time)
    
    // Performance should be reasonable
    testing.expect(t, avg_add_time < 1.0, "Average add time should be reasonable")
    testing.expect(t, avg_remove_time < 1.0, "Average remove time should be reasonable")
    testing.expect(t, max_add_time < 10.0, "Max add time should not be excessive")
    testing.expect(t, max_remove_time < 10.0, "Max remove time should not be excessive")
    
    // Final state should be empty
    final_count := crowd.crowd_get_active_agent_count(crowd_system)
    testing.expect(t, final_count == 0, "Should have no active agents after churn test")
}

@(test)
test_proximity_grid_stress :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    grid := new(crowd.Proximity_Grid)
    defer free(grid)
    
    max_items := i32(500)  // Stress test capacity
    cell_size := f32(2.0)
    
    crowd.proximity_grid_init(grid, max_items, cell_size)
    defer crowd.proximity_grid_destroy(grid)
    
    // Add many items in different patterns
    // rand.set_global_seed(54321)
    
    add_times := make([dynamic]f64, 0, max_items)
    query_times := make([dynamic]f64, 0, 100)
    defer delete(add_times)
    defer delete(query_times)
    
    // Phase 1: Add items with timing
    for i in 1..=max_items {
        min_x := rand.float32_range(-50.0, 50.0)
        min_z := rand.float32_range(-50.0, 50.0)
        max_x := min_x + rand.float32_range(0.5, 2.0)
        max_z := min_z + rand.float32_range(0.5, 2.0)
        
        add_start := time.now()
        status := crowd.proximity_grid_add_item(grid, u16(i), min_x, min_z, max_x, max_z)
        add_time := f64(time.duration_microseconds(time.since(add_start))) / 1000.0
        
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add item %d", i))
        append(&add_times, add_time)
        
        if i % 100 == 0 {
            fmt.printf("Added %d items\n", i)
        }
    }
    
    // Verify all items added
    item_count := crowd.proximity_grid_get_item_count(grid)
    testing.expect(t, item_count == max_items, "Should have all items added")
    
    // Phase 2: Query stress test
    result_buffer := make([]u16, 100)
    defer delete(result_buffer)
    
    for query in 0..<100 {
        query_x := rand.float32_range(-40.0, 40.0)
        query_z := rand.float32_range(-40.0, 40.0)
        radius := rand.float32_range(5.0, 15.0)
        
        query_start := time.now()
        result_count := crowd.proximity_grid_query_items(grid, query_x, query_z, radius, result_buffer[:], 100)
        query_time := f64(time.duration_microseconds(time.since(query_start))) / 1000.0
        
        testing.expect(t, result_count >= 0, "Query should return valid count")
        testing.expect(t, result_count <= 100, "Query should not exceed buffer size")
        append(&query_times, query_time)
    }
    
    // Calculate performance statistics
    total_add_time := f64(0.0)
    max_add_time := f64(0.0)
    for add_time in add_times {
        total_add_time += add_time
        max_add_time = max(max_add_time, add_time)
    }
    avg_add_time := total_add_time / f64(len(add_times))
    
    total_query_time := f64(0.0)
    max_query_time := f64(0.0)
    for query_time in query_times {
        total_query_time += query_time
        max_query_time = max(max_query_time, query_time)
    }
    avg_query_time := total_query_time / f64(len(query_times))
    
    fmt.printf("Proximity grid stress test (%d items):\n", max_items)
    fmt.printf("  Add - Avg: %.3f ms, Max: %.3f ms\n", avg_add_time, max_add_time)
    fmt.printf("  Query - Avg: %.3f ms, Max: %.3f ms\n", avg_query_time, max_query_time)
    
    // Memory usage
    items_mem, buckets_mem, total_mem := crowd.proximity_grid_get_memory_usage(grid)
    fmt.printf("  Memory - Items: %d bytes, Buckets: %d bytes, Total: %d bytes\n",
              items_mem, buckets_mem, total_mem)
    
    // Performance expectations (these are rough guidelines)
    testing.expect(t, avg_add_time < 0.1, "Average add time should be fast")
    testing.expect(t, avg_query_time < 1.0, "Average query time should be reasonable")
    testing.expect(t, max_add_time < 5.0, "Max add time should not be excessive")
    testing.expect(t, max_query_time < 10.0, "Max query time should not be excessive")
}

// =============================================================================
// Emergency Scenario Tests
// =============================================================================

@(test)
test_emergency_target_change :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    agent_count := i32(30)
    crowd_system := create_test_crowd(t, nav_mesh, agent_count)
    defer destroy_test_crowd(crowd_system)
    
    // Create agents spread across the map
    agents := make([]recast.Agent_Id, agent_count)
    defer delete(agents)
    
    params := crowd.agent_params_create_default()
    
    for i in 0..<agent_count {
        pos := [3]f32{
            f32(8 + (i % 6) * 3),  // 6x5 grid approximately
            0.0,
            f32(8 + (i / 6) * 3),
        }
        
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add agent %d", i))
        agents[i] = agent_id
    }
    
    // Initial target: all agents move to center
    initial_target := [3]f32{15.0, 0.0, 15.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    _, initial_ref, initial_nearest := detour.find_nearest_poly(
        crowd_system.nav_query, initial_target, half_extents, filter
    )
    
    // Set initial targets
    for agent_id in agents {
        crowd.crowd_request_move_target(crowd_system, agent_id, initial_ref, initial_nearest)
    }
    
    // Let agents start moving
    for i in 0..<10 {
        crowd.crowd_update(crowd_system, 0.1, nil)
    }
    
    // EMERGENCY: All agents suddenly need to go to corner
    emergency_target := [3]f32{5.0, 0.0, 5.0}
    
    _, emergency_ref, emergency_nearest := detour.find_nearest_poly(
        crowd_system.nav_query, emergency_target, half_extents, filter
    )
    
    // Measure time to change all targets
    emergency_start := time.now()
    
    for agent_id in agents {
        status := crowd.crowd_request_move_target(crowd_system, agent_id, emergency_ref, emergency_nearest)
        testing.expect(t, recast.status_succeeded(status), "Emergency target change should succeed")
    }
    
    emergency_time := time.duration_microseconds(time.since(emergency_start))
    
    fmt.printf("Emergency target change for %d agents: %.2f ms\n",
              agent_count, f64(emergency_time) / 1000.0)
    
    // Monitor system stability during emergency response
    stability_frames := 20
    error_count := 0
    
    for frame in 0..<stability_frames {
        status := crowd.crowd_update(crowd_system, 0.1, nil)
        if recast.status_failed(status) {
            error_count += 1
        }
        
        // Check that agents are responding to emergency
        agents_responding := 0
        for agent_id in agents {
            agent := crowd.crowd_get_agent(crowd_system, agent_id)
            if agent == nil do continue
            
            target_state := crowd.agent_get_target_state(agent)
            if target_state != .None && target_state != .Failed {
                agents_responding += 1
            }
        }
        
        if frame % 5 == 0 {
            fmt.printf("Emergency frame %d: %d agents responding, %d errors\n",
                      frame, agents_responding, error_count)
        }
    }
    
    // Evaluate emergency response
    testing.expect(t, error_count == 0, "Should have no update errors during emergency")
    
    // Check final response
    final_responding := 0
    final_progress := 0
    
    for agent_id in agents {
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        if agent == nil do continue
        
        target_state := crowd.agent_get_target_state(agent)
        if target_state != .None && target_state != .Failed {
            final_responding += 1
        }
        
        // Check if agent made progress toward emergency target
        distance_to_emergency := linalg.distance(agent.position, emergency_target)
        if distance_to_emergency < 15.0 {  // Reasonable progress
            final_progress += 1
        }
    }
    
    fmt.printf("Emergency response results:\n")
    fmt.printf("  Agents responding: %d/%d\n", final_responding, agent_count)
    fmt.printf("  Agents making progress: %d/%d\n", final_progress, agent_count)
    fmt.printf("  Target change time: %.2f ms\n", f64(emergency_time) / 1000.0)
    
    testing.expect(t, final_responding >= int(agent_count) * 3 / 4, 
                  "Most agents should respond to emergency")
    testing.expect(t, final_progress > 0, "Some agents should make progress")
    testing.expect(t, f64(emergency_time) / 1000.0 < 10.0, "Emergency response should be fast")
}