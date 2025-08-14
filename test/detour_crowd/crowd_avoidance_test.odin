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
// Obstacle Avoidance Query Unit Tests
// =============================================================================

@(test)
test_obstacle_avoidance_query_circle_exact_values :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    query := new(crowd.Obstacle_Avoidance_Query)
    defer free(query)
    
    // Initialize with exact capacities
    status := crowd.obstacle_avoidance_query_init(query, 10, 20)
    testing.expect(t, recast.status_succeeded(status), "Failed to initialize obstacle avoidance query")
    defer crowd.obstacle_avoidance_query_destroy(query)
    
    // Verify exact initial state
    testing.expect(t, query.max_circles == 10, "Max circles should be exactly 10")
    testing.expect(t, query.max_segments == 20, "Max segments should be exactly 20")
    testing.expect(t, len(query.circle_obstacles) == 0, "Should start with 0 circle obstacles")
    testing.expect(t, len(query.segment_obstacles) == 0, "Should start with 0 segment obstacles")
    
    // Add circle obstacle with exact parameters
    obstacle_pos := [3]f32{5.0, 0.0, 5.0}
    obstacle_vel := [3]f32{1.0, 0.0, 0.0}
    obstacle_dvel := [3]f32{0.5, 0.0, 0.0}
    obstacle_radius := f32(1.5)
    displacement := [3]f32{0.0, 0.0, 1.0}
    next_pos := [3]f32{6.0, 0.0, 5.0}
    
    add_status := crowd.obstacle_avoidance_query_add_circle(
        query, obstacle_pos, obstacle_vel, obstacle_dvel, obstacle_radius, displacement, next_pos
    )
    testing.expect(t, recast.status_succeeded(add_status), "Should add circle obstacle")
    testing.expect(t, len(query.circle_obstacles) == 1, "Should have exactly 1 circle obstacle")
    
    // Verify exact circle obstacle values
    circle := query.circle_obstacles[0]
    testing.expect(t, circle.position == obstacle_pos, "Circle position should match exactly")
    testing.expect(t, circle.velocity == obstacle_vel, "Circle velocity should match exactly")
    testing.expect(t, circle.desired_velocity == obstacle_dvel, "Circle desired velocity should match exactly")
    testing.expect(t, circle.radius == obstacle_radius, "Circle radius should match exactly")
    testing.expect(t, circle.displacement == displacement, "Circle displacement should match exactly")
    testing.expect(t, circle.next_position == next_pos, "Circle next position should match exactly")
}

@(test)
test_obstacle_avoidance_query_segment_exact_values :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    query := new(crowd.Obstacle_Avoidance_Query)
    defer free(query)
    
    crowd.obstacle_avoidance_query_init(query, 5, 15)
    defer crowd.obstacle_avoidance_query_destroy(query)
    
    // Add segment obstacle with exact parameters
    seg_start := [3]f32{0.0, 0.0, 0.0}
    seg_end := [3]f32{10.0, 0.0, 0.0}
    touch := true
    
    add_status := crowd.obstacle_avoidance_query_add_segment(query, seg_start, seg_end, touch)
    testing.expect(t, recast.status_succeeded(add_status), "Should add segment obstacle")
    testing.expect(t, len(query.segment_obstacles) == 1, "Should have exactly 1 segment obstacle")
    
    // Verify exact segment obstacle values
    segment := query.segment_obstacles[0]
    testing.expect(t, segment.start_pos == seg_start, "Segment start should match exactly")
    testing.expect(t, segment.end_pos == seg_end, "Segment end should match exactly")
    testing.expect(t, segment.touch == touch, "Segment touch flag should match exactly")
}

@(test)
test_obstacle_avoidance_velocity_sampling_grid :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    query := new(crowd.Obstacle_Avoidance_Query)
    defer free(query)
    
    crowd.obstacle_avoidance_query_init(query, 5, 10)
    defer crowd.obstacle_avoidance_query_destroy(query)
    
    // Set up specific avoidance parameters
    params := crowd.Obstacle_Avoidance_Params{
        vel_bias = 0.4,
        weight_des_vel = 2.0,
        weight_cur_vel = 0.75,
        weight_side = 0.75,
        weight_toi = 2.5,
        horiz_time = 2.5,
        grid_size = 21,  // Specific grid size for predictable sampling
        adaptive_divs = 7,
        adaptive_rings = 2,
        adaptive_depth = 5,
    }
    
    // Add a circular obstacle
    obstacle_pos := [3]f32{3.0, 0.0, 0.0}
    obstacle_vel := [3]f32{0.0, 0.0, 0.0}
    obstacle_dvel := [3]f32{0.0, 0.0, 0.0}
    obstacle_radius := f32(1.0)
    
    crowd.obstacle_avoidance_query_add_circle(
        query, obstacle_pos, obstacle_vel, obstacle_dvel, obstacle_radius, {}, {}
    )
    
    // Test velocity sampling with exact parameters
    agent_pos := [3]f32{0.0, 0.0, 0.0}
    current_vel := [3]f32{1.0, 0.0, 0.0}  // Moving toward obstacle
    desired_vel := [3]f32{2.0, 0.0, 0.0}  // Faster toward obstacle
    agent_radius := f32(0.5)
    desired_vel_mag := linalg.length(desired_vel)
    
    debug_data := new(crowd.Obstacle_Avoidance_Debug_Data)
    defer free(debug_data)
    crowd.obstacle_avoidance_debug_data_init(debug_data, 1000)
    defer crowd.obstacle_avoidance_debug_data_destroy(debug_data)
    
    // Sample velocity using grid method
    result_vel := crowd.obstacle_avoidance_query_sample_velocity_grid(
        query, agent_pos, current_vel, desired_vel, agent_radius, desired_vel_mag, &params, debug_data
    )
    sample_count := i32(len(debug_data.sample_velocities))
    
    // Verify sampling results
    testing.expect(t, sample_count > 0, "Should generate velocity samples")
    max_samples := i32(params.grid_size) * i32(params.grid_size)
    testing.expect(t, sample_count <= max_samples, 
                  fmt.tprintf("Sample count %d should not exceed grid capacity %d", sample_count, max_samples))
    
    // Verify result velocity is reasonable (should avoid obstacle)
    result_speed := linalg.length(result_vel)
    testing.expect(t, result_speed >= 0.0, "Result velocity should have non-negative magnitude")
    
    // For this setup, result should not point directly at obstacle
    to_obstacle := linalg.normalize(obstacle_pos - agent_pos)
    vel_normalized := result_vel
    if result_speed > 0.01 {
        vel_normalized = result_vel / result_speed
        dot_product := linalg.dot(vel_normalized, to_obstacle)
        // Should not be moving directly toward obstacle (some avoidance)
        testing.expect(t, dot_product < 0.9, "Should show some obstacle avoidance")
    }
    
    fmt.printf("Grid sampling: samples=%d, result_vel=(%.3f,%.3f,%.3f), speed=%.3f\n",
              sample_count, result_vel.x, result_vel.y, result_vel.z, result_speed)
}

@(test)
test_obstacle_avoidance_velocity_sampling_adaptive :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    query := new(crowd.Obstacle_Avoidance_Query)
    defer free(query)
    
    crowd.obstacle_avoidance_query_init(query, 3, 5)
    defer crowd.obstacle_avoidance_query_destroy(query)
    
    // Set parameters for adaptive sampling
    params := crowd.Obstacle_Avoidance_Params{
        vel_bias = 0.6,
        weight_des_vel = 1.5,
        weight_cur_vel = 1.0,
        weight_side = 0.5,
        weight_toi = 3.0,
        horiz_time = 3.0,
        grid_size = 33,
        adaptive_divs = 9,  // Higher for more adaptive samples
        adaptive_rings = 3,
        adaptive_depth = 6,
    }
    
    // Create multiple obstacles for complex scenario
    obstacles := [][3]f32{
        {2.0, 0.0, 1.0},   // Right-forward
        {2.0, 0.0, -1.0},  // Right-back
        {1.0, 0.0, 0.0},   // Forward
    }
    
    for obs_pos in obstacles {
        crowd.obstacle_avoidance_query_add_circle(
            query, obs_pos, {}, {}, 0.8, {}, {}
        )
    }
    
    // Agent parameters
    agent_pos := [3]f32{0.0, 0.0, 0.0}
    current_vel := [3]f32{0.5, 0.0, 0.0}
    desired_vel := [3]f32{3.0, 0.0, 0.0}
    agent_radius := f32(0.4)
    desired_vel_mag_2 := linalg.length(desired_vel)
    
    debug_data := new(crowd.Obstacle_Avoidance_Debug_Data)
    defer free(debug_data)
    crowd.obstacle_avoidance_debug_data_init(debug_data, 2000)
    defer crowd.obstacle_avoidance_debug_data_destroy(debug_data)
    
    // Sample using adaptive method
    result_vel := crowd.obstacle_avoidance_query_sample_velocity_adaptive(
        query, agent_pos, current_vel, desired_vel, agent_radius, desired_vel_mag_2, &params, debug_data
    )
    sample_count := i32(len(debug_data.sample_velocities))
    
    // Verify adaptive sampling
    testing.expect(t, sample_count > 0, "Should generate adaptive samples")
    
    // Adaptive should potentially generate more samples than basic grid
    expected_min_samples := i32(params.adaptive_divs * params.adaptive_rings)
    testing.expect(t, sample_count >= expected_min_samples, "Should meet minimum adaptive sample count")
    
    result_speed := linalg.length(result_vel)
    testing.expect(t, result_speed >= 0.0, "Result speed should be non-negative")
    
    // In complex obstacle field, should find reasonable avoidance velocity
    if result_speed > 0.01 {
        vel_dir := result_vel / result_speed
        
        // Check that result doesn't point directly at any obstacle
        safe_direction := true
        for obs_pos in obstacles {
            to_obstacle := linalg.normalize(obs_pos - agent_pos)
            dot := linalg.dot(vel_dir, to_obstacle)
            if dot > 0.95 {  // Almost directly toward obstacle
                safe_direction = false
                break
            }
        }
        
        testing.expect(t, safe_direction, "Adaptive sampling should avoid pointing directly at obstacles")
    }
    
    fmt.printf("Adaptive sampling: samples=%d, result_vel=(%.3f,%.3f,%.3f), speed=%.3f\n",
              sample_count, result_vel.x, result_vel.y, result_vel.z, result_speed)
}

@(test)
test_obstacle_avoidance_parameters_configuration :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    query := new(crowd.Obstacle_Avoidance_Query)
    defer free(query)
    
    crowd.obstacle_avoidance_query_init(query, 5, 5)
    defer crowd.obstacle_avoidance_query_destroy(query)
    
    // Test setting parameters at different indices
    low_quality := crowd.Obstacle_Avoidance_Params{
        vel_bias = 0.2,
        weight_des_vel = 1.0,
        weight_cur_vel = 0.5,
        weight_side = 0.3,
        weight_toi = 1.5,
        horiz_time = 1.5,
        grid_size = 15,
        adaptive_divs = 5,
        adaptive_rings = 1,
        adaptive_depth = 3,
    }
    
    high_quality := crowd.Obstacle_Avoidance_Params{
        vel_bias = 0.8,
        weight_des_vel = 3.0,
        weight_cur_vel = 1.5,
        weight_side = 1.2,
        weight_toi = 4.0,
        horiz_time = 4.0,
        grid_size = 65,
        adaptive_divs = 11,
        adaptive_rings = 4,
        adaptive_depth = 8,
    }
    
    // Set parameters at different indices
    set_status_0 := crowd.obstacle_avoidance_query_set_params(query, 0, low_quality)
    testing.expect(t, recast.status_succeeded(set_status_0), "Should set params at index 0")
    
    set_status_1 := crowd.obstacle_avoidance_query_set_params(query, 1, high_quality)
    testing.expect(t, recast.status_succeeded(set_status_1), "Should set params at index 1")
    
    // Retrieve and verify exact values
    retrieved_low := crowd.obstacle_avoidance_query_get_params(query, 0)
    testing.expect(t, retrieved_low != nil, "Should retrieve params at index 0")
    if retrieved_low != nil {
        testing.expect(t, retrieved_low.vel_bias == 0.2, "Low quality vel_bias should be 0.2")
        testing.expect(t, retrieved_low.grid_size == 15, "Low quality grid_size should be 15")
        testing.expect(t, retrieved_low.adaptive_divs == 5, "Low quality adaptive_divs should be 5")
    }
    
    retrieved_high := crowd.obstacle_avoidance_query_get_params(query, 1)
    testing.expect(t, retrieved_high != nil, "Should retrieve params at index 1")
    if retrieved_high != nil {
        testing.expect(t, retrieved_high.vel_bias == 0.8, "High quality vel_bias should be 0.8")
        testing.expect(t, retrieved_high.grid_size == 65, "High quality grid_size should be 65")
        testing.expect(t, retrieved_high.adaptive_divs == 11, "High quality adaptive_divs should be 11")
    }
    
    // Test invalid index
    invalid_params := crowd.obstacle_avoidance_query_get_params(query, 999)
    testing.expect(t, invalid_params == nil, "Should return nil for invalid index")
}

// =============================================================================
// Agent Collision Avoidance Integration Tests
// =============================================================================

@(test)
test_agent_neighbor_detection_exact_distances :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 10)
    defer destroy_test_crowd(crowd_system)
    
    // Place agents at exact known positions
    agent_positions := [][3]f32{
        {10.0, 0.0, 10.0},  // Center agent
        {11.0, 0.0, 10.0},  // 1 unit east
        {12.0, 0.0, 10.0},  // 2 units east
        {10.0, 0.0, 11.0},  // 1 unit north
        {10.0, 0.0, 12.0},  // 2 units north  
        {15.0, 0.0, 15.0},  // Far agent (should not be neighbor)
    }
    
    agents := make([]recast.Agent_Id, len(agent_positions))
    defer delete(agents)
    
    for pos, i in agent_positions {
        params := crowd.agent_params_create_default()
        params.collision_query_range = 5.0  // Limited range for predictable neighbor detection
        
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        testing.expect(t, recast.status_succeeded(status), fmt.tprintf("Should add agent %d", i))
        agents[i] = agent_id
    }
    
    // Update crowd to establish neighbor relationships
    crowd.crowd_update(crowd_system, 0.1, nil)
    
    // Check center agent (index 0) neighbors
    center_agent := crowd.crowd_get_agent(crowd_system, agents[0])
    testing.expect(t, center_agent != nil, "Center agent should exist")
    
    neighbor_count := crowd.agent_get_neighbor_count(center_agent)
    testing.expect(t, neighbor_count > 0, "Center agent should have neighbors")
    testing.expect(t, neighbor_count <= crowd.DT_CROWD_MAX_NEIGHBORS, "Should not exceed max neighbors")
    
    // Verify exact neighbor distances and indices
    found_neighbors := make(map[i32]f32)  // agent_index -> distance
    defer delete(found_neighbors)
    
    for i in 0..<neighbor_count {
        neighbor, found := crowd.agent_get_neighbor(center_agent, i)
        testing.expect(t, found, "Should find neighbor at valid index")
        
        if found {
            testing.expect(t, neighbor.agent_index >= 0, "Neighbor index should be valid")
            testing.expect(t, neighbor.distance > 0.0, "Neighbor distance should be positive")
            
            found_neighbors[neighbor.agent_index] = neighbor.distance
        }
    }
    
    // Verify expected neighbors with exact distances
    // Agent 1 (11,0,10) should be distance 1.0 from center (10,0,10)
    if dist, exists := found_neighbors[1]; exists {
        testing.expect(t, math.abs(dist - 1.0) < 0.1, "Agent 1 should be ~1.0 units away")
    }
    
    // Agent 3 (10,0,11) should be distance 1.0 from center
    if dist, exists := found_neighbors[3]; exists {
        testing.expect(t, math.abs(dist - 1.0) < 0.1, "Agent 3 should be ~1.0 units away")
    }
    
    // Far agent (index 5) should not be a neighbor
    _, far_agent_is_neighbor := found_neighbors[5]
    testing.expect(t, !far_agent_is_neighbor, "Far agent should not be neighbor")
    
    fmt.printf("Center agent neighbors: count=%d, neighbors=%v\n", neighbor_count, found_neighbors)
}

@(test)
test_bidirectional_collision_avoidance :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 5)
    defer destroy_test_crowd(crowd_system)
    
    // Create two agents moving toward each other
    agent1_start := [3]f32{5.0, 0.0, 15.0}
    agent2_start := [3]f32{25.0, 0.0, 15.0}
    
    agent1_id := add_test_agent(t, crowd_system, agent1_start)
    agent2_id := add_test_agent(t, crowd_system, agent2_start)
    
    // Set targets so agents move toward each other
    target1 := [3]f32{25.0, 0.0, 15.0}  // Agent1 moves to Agent2's start
    target2 := [3]f32{5.0, 0.0, 15.0}   // Agent2 moves to Agent1's start
    
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    _, target_ref1, nearest_target1 := detour.find_nearest_poly(crowd_system.nav_query, target1, half_extents, filter)
    _, target_ref2, nearest_target2 := detour.find_nearest_poly(crowd_system.nav_query, target2, half_extents, filter)
    
    crowd.crowd_request_move_target(crowd_system, agent1_id, target_ref1, nearest_target1)
    crowd.crowd_request_move_target(crowd_system, agent2_id, target_ref2, nearest_target2)
    
    // Record initial distance between agents
    agent1 := crowd.crowd_get_agent(crowd_system, agent1_id)
    agent2 := crowd.crowd_get_agent(crowd_system, agent2_id)
    initial_distance := linalg.distance(agent1.position, agent2.position)
    
    testing.expect(t, initial_distance > 15.0, "Agents should start far apart")
    
    min_separation := f32(1.15)  // Minimum allowed separation (slightly less than combined radii to allow contact)
    collision_occurred := false
    
    // Simulate until agents meet
    for step in 0..<60 {
        crowd.crowd_update(crowd_system, 0.1, nil)
        
        agent1 = crowd.crowd_get_agent(crowd_system, agent1_id)
        agent2 = crowd.crowd_get_agent(crowd_system, agent2_id)
        
        if agent1 == nil || agent2 == nil do break
        
        current_distance := linalg.distance(agent1.position, agent2.position)
        
        // Check for collision
        if current_distance < min_separation {
            collision_occurred = true
            fmt.printf("Collision detected at step %d: distance=%.3f\n", step, current_distance)
        }
        
        // Check neighbor detection
        if step >= 10 && current_distance < 8.0 {  // When agents are reasonably close
            neighbor_count1 := crowd.agent_get_neighbor_count(agent1)
            neighbor_count2 := crowd.agent_get_neighbor_count(agent2)
            
            // Agents should detect each other as neighbors
            if neighbor_count1 > 0 {
                neighbor, found := crowd.agent_get_neighbor(agent1, 0)
                if found {
                    testing.expect(t, neighbor.agent_index == 1, "Agent1 should detect agent2 as neighbor")
                    testing.expect(t, math.abs(neighbor.distance - current_distance) < 0.5,
                                  "Neighbor distance should match actual distance")
                }
            }
        }
        
        // Log progress periodically
        if step % 10 == 0 {
            fmt.printf("Step %d: agent1=(%.2f,%.2f), agent2=(%.2f,%.2f), dist=%.2f\n",
                      step, agent1.position.x, agent1.position.z, 
                      agent2.position.x, agent2.position.z, current_distance)
        }
        
        // Break when agents have crossed paths
        if current_distance > initial_distance * 0.8 && step > 20 {
            break
        }
    }
    
    // Verify collision avoidance worked
    testing.expect(t, !collision_occurred, "Agents should avoid collision")
    
    // Verify both agents made progress toward their goals
    final_agent1 := crowd.crowd_get_agent(crowd_system, agent1_id)
    final_agent2 := crowd.crowd_get_agent(crowd_system, agent2_id)
    
    if final_agent1 != nil && final_agent2 != nil {
        progress1 := linalg.distance(final_agent1.position, target1)
        initial_dist1 := linalg.distance(agent1_start, target1)
        
        progress2 := linalg.distance(final_agent2.position, target2)
        initial_dist2 := linalg.distance(agent2_start, target2)
        
        testing.expect(t, progress1 < initial_dist1 * 0.8, "Agent1 should make significant progress")
        testing.expect(t, progress2 < initial_dist2 * 0.8, "Agent2 should make significant progress")
    }
}

@(test)
test_separation_force_calculation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 8)
    defer destroy_test_crowd(crowd_system)
    
    // Create cluster of agents
    center_pos := [3]f32{15.0, 0.0, 15.0}
    cluster_positions := [][3]f32{
        {15.0, 0.0, 15.0},   // Center
        {15.5, 0.0, 15.0},   // East
        {14.5, 0.0, 15.0},   // West  
        {15.0, 0.0, 15.5},   // North
        {15.0, 0.0, 14.5},   // South
        {15.3, 0.0, 15.3},   // Northeast
    }
    
    agents := make([]recast.Agent_Id, len(cluster_positions))
    defer delete(agents)
    
    // Set agents with high separation weights
    for pos, i in cluster_positions {
        params := crowd.agent_params_create_default()
        params.separation_weight = 3.0  // High separation
        params.radius = 0.4
        
        agent_id, status := crowd.crowd_add_agent(crowd_system, pos, &params)
        testing.expect(t, recast.status_succeeded(status), "Should add agent")
        agents[i] = agent_id
    }
    
    // Set common target to force agents to stay clustered initially
    target_pos := [3]f32{20.0, 0.0, 20.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    _, target_ref, nearest_target := detour.find_nearest_poly(crowd_system.nav_query, target_pos, half_extents, filter)
    
    for agent_id in agents {
        crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    }
    
    // Update to establish separation
    for step in 0..<30 {
        crowd.crowd_update(crowd_system, 0.1, nil)
        
        if step == 10 || step == 20 || step == 29 {
            // Check separation at specific steps
            min_distance := f32(999.0)
            max_distance := f32(0.0)
            
            for i in 0..<len(agents) {
                agent_i := crowd.crowd_get_agent(crowd_system, agents[i])
                if agent_i == nil do continue
                
                for j in i+1..<len(agents) {
                    agent_j := crowd.crowd_get_agent(crowd_system, agents[j])
                    if agent_j == nil do continue
                    
                    distance := linalg.distance(agent_i.position, agent_j.position)
                    min_distance = min(min_distance, distance)
                    max_distance = max(max_distance, distance)
                }
            }
            
            testing.expect(t, min_distance > 0.5, "Agents should maintain minimum separation")
            fmt.printf("Step %d separation: min=%.3f, max=%.3f\n", step, min_distance, max_distance)
        }
    }
    
    // Verify final separation is reasonable
    center_agent := crowd.crowd_get_agent(crowd_system, agents[0])
    if center_agent != nil {
        neighbor_count := crowd.agent_get_neighbor_count(center_agent)
        testing.expect(t, neighbor_count > 0, "Center agent should have neighbors")
        
        // Verify neighbors are not too close
        for i in 0..<neighbor_count {
            neighbor, found := crowd.agent_get_neighbor(center_agent, i)
            if found {
                testing.expect(t, neighbor.distance > 0.3, "Neighbors should maintain reasonable distance")
            }
        }
    }
}

// =============================================================================
// Obstacle Avoidance System Tests
// =============================================================================

@(test)
test_complete_obstacle_avoidance_workflow :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    crowd_system := create_test_crowd(t, nav_mesh, 6)
    defer destroy_test_crowd(crowd_system)
    
    // Configure different obstacle avoidance qualities
    low_quality := crowd.obstacle_avoidance_params_create_low_quality()
    high_quality := crowd.obstacle_avoidance_params_create_high_quality()
    
    crowd.crowd_set_obstacle_avoidance_params(crowd_system, 0, &low_quality)
    crowd.crowd_set_obstacle_avoidance_params(crowd_system, 1, &high_quality)
    
    // Create agents with different avoidance types
    // Note: Avoid placing agents exactly on vertices (multiples of 10)
    agent_configs := []struct {
        pos: [3]f32,
        avoidance_type: u8,
    }{
        {{10.1, 0.0, 10.1}, 0},  // Low quality - slightly offset from vertex
        {{12.0, 0.0, 10.0}, 1},  // High quality
        {{14.0, 0.0, 10.0}, 0},  // Low quality
        {{16.0, 0.0, 10.0}, 1},  // High quality
    }
    
    agents := make([]recast.Agent_Id, len(agent_configs))
    defer delete(agents)
    
    for config, i in agent_configs {
        params := crowd.agent_params_create_default()
        params.obstacle_avoidance_type = config.avoidance_type
        
        agent_id, status := crowd.crowd_add_agent(crowd_system, config.pos, &params)
        testing.expect(t, recast.status_succeeded(status), "Should add agent")
        agents[i] = agent_id
    }
    
    // Set targets that require navigation through potential obstacles
    target_pos := [3]f32{25.0, 0.0, 15.0}
    half_extents := [3]f32{2.0, 2.0, 2.0}
    filter := crowd.crowd_get_filter(crowd_system, 0)
    
    _, target_ref, nearest_target := detour.find_nearest_poly(crowd_system.nav_query, target_pos, half_extents, filter)
    
    for agent_id in agents {
        crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, nearest_target)
    }
    
    // Simulate and monitor avoidance behavior
    for step in 0..<40 {
        crowd.crowd_update(crowd_system, 0.1, nil)
        
        if step % 8 == 0 || step == 0 {
            fmt.printf("Step %d obstacle avoidance analysis:\n", step)
            
            for agent_id, i in agents {
                agent := crowd.crowd_get_agent(crowd_system, agent_id)
                if agent == nil do continue
                
                // Check avoidance type is preserved
                testing.expect(t, agent.params.obstacle_avoidance_type == agent_configs[i].avoidance_type,
                              "Agent should maintain its avoidance type")
                
                // Analyze velocity changes (indicating avoidance)
                vel_magnitude := linalg.length(agent.velocity)
                desired_vel_magnitude := linalg.length(agent.desired_velocity)
                
                fmt.printf("  Agent %d (type %d): pos=(%.2f,%.2f,%.2f) vel_mag=%.3f, desired_vel_mag=%.3f corners=%d\n",
                          i, agent.params.obstacle_avoidance_type, 
                          agent.position.x, agent.position.y, agent.position.z,
                          vel_magnitude, desired_vel_magnitude, agent.corner_count)
                
                // Verify reasonable velocity magnitude
                testing.expect(t, vel_magnitude >= 0.0, "Velocity magnitude should be non-negative")
                testing.expect(t, vel_magnitude <= agent.params.max_speed * 1.1, 
                              "Velocity should not significantly exceed max speed")
            }
        }
    }
    
    // Verify all agents made progress
    for agent_id, i in agents {
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        if agent != nil {
            start_pos := agent_configs[i].pos
            progress := linalg.distance(start_pos, agent.position)
            corridor_path_count := len(agent.corridor.path) if agent.corridor.path != nil else 0
            // Debug output disabled
            // fmt.printf("Agent %d: start=(%.2f,%.2f,%.2f) end=(%.2f,%.2f,%.2f) progress=%.3f state=%v targetState=%v corners=%d pathLen=%d\n",
            //           i, start_pos.x, start_pos.y, start_pos.z, 
            //           agent.position.x, agent.position.y, agent.position.z,
            //           progress, agent.state, agent.target_state, agent.corner_count, corridor_path_count)
            testing.expect(t, progress > 2.0, "Agent should make meaningful progress")
        }
    }
}