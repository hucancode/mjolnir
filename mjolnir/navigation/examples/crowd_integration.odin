package navigation_examples

import "core:fmt"
import "core:time"
import nav_recast "../recast"
import detour "../detour"
import crowd "../detour_crowd"

// Example demonstrating basic crowd simulation usage
crowd_basic_example :: proc() {
    fmt.println("=== DetourCrowd Basic Example ===")
    
    // Note: In a real application, you would load a navigation mesh from file
    // This example shows the API usage with a mock setup
    
    // Step 1: Create a navigation mesh query (typically loaded from file)
    nav_query := create_example_nav_query()
    defer cleanup_example_nav_query(nav_query)
    
    // Step 2: Create crowd manager
    crowd_system, create_status := crowd.crowd_create(10, 2.0, nav_query)
    if crowd.status_failed(create_status) {
        fmt.printf("Failed to create crowd: %v\n", create_status)
        return
    }
    defer crowd.crowd_destroy(crowd_system)
    
    fmt.printf("Created crowd system with max %d agents\n", crowd.crowd_get_agent_count(crowd_system))
    
    // Step 3: Configure obstacle avoidance parameters
    obstacle_params := crowd.obstacle_avoidance_params_create_medium_quality()
    crowd.crowd_set_obstacle_avoidance_params(crowd_system, 0, &obstacle_params)
    
    // Step 4: Add agents to the crowd
    agents := make([]nav_recast.Agent_Id, 3)
    defer delete(agents)
    
    // Add soldier agent
    soldier_params := crowd.agent_params_create_soldier()
    agents[0], _ = crowd.crowd_add_agent(crowd_system, {0, 0, 0}, &soldier_params)
    
    // Add civilian agent
    civilian_params := crowd.agent_params_create_civilian()
    agents[1], _ = crowd.crowd_add_agent(crowd_system, {2, 0, 0}, &civilian_params)
    
    // Add vehicle
    vehicle_params := crowd.agent_params_create_vehicle()
    agents[2], _ = crowd.crowd_add_agent(crowd_system, {-2, 0, 0}, &vehicle_params)
    
    fmt.printf("Added %d agents to crowd\n", len(agents))
    
    // Step 5: Set movement targets for agents
    target_ref := nav_recast.Poly_Ref(1)  // Mock polygon reference
    
    crowd.crowd_request_move_target(crowd_system, agents[0], target_ref, {10, 0, 0})
    crowd.crowd_request_move_target(crowd_system, agents[1], target_ref, {8, 0, 2})
    crowd.crowd_request_move_velocity(crowd_system, agents[2], {1, 0, 0})  // Vehicle uses velocity control
    
    // Step 6: Run simulation loop
    dt := f32(1.0/60.0)  // 60 FPS
    total_time := f32(0)
    
    for i in 0..<300 {  // Run for 5 seconds
        // Update crowd simulation
        update_status := crowd.crowd_update(crowd_system, dt)
        if crowd.status_failed(update_status) {
            fmt.printf("Crowd update failed: %v\n", update_status)
            break
        }
        
        total_time += dt
        
        // Print agent states every second
        if i % 60 == 0 {
            fmt.printf("\n--- Time: %.1fs ---\n", total_time)
            
            for j, agent_id in agents {
                agent := crowd.crowd_get_agent(crowd_system, agent_id)
                if agent != nil {
                    pos := crowd.agent_get_position(agent)
                    vel := crowd.agent_get_velocity(agent)
                    state := crowd.agent_get_state(agent)
                    target_state := crowd.agent_get_target_state(agent)
                    
                    fmt.printf("Agent %d: pos=(%.2f,%.2f,%.2f) vel=(%.2f,%.2f,%.2f) state=%v target=%v\n",
                              j, pos.x, pos.y, pos.z, vel.x, vel.y, vel.z, state, target_state)
                }
            }
        }
    }
    
    // Step 7: Print final statistics
    stats := crowd.crowd_get_statistics(crowd_system)
    fmt.printf("\nFinal Statistics:\n")
    fmt.printf("  Active agents: %d/%d\n", stats.active_agents, stats.max_agents)
    fmt.printf("  Path queue: %d/%d\n", stats.queue_size, stats.max_queue_size)
    fmt.printf("  Pending requests: %d\n", stats.pending_path_requests)
    fmt.printf("  Completed requests: %d\n", stats.completed_path_requests)
}

// Example demonstrating advanced crowd features
crowd_advanced_example :: proc() {
    fmt.println("\n=== DetourCrowd Advanced Example ===")
    
    nav_query := create_example_nav_query()
    defer cleanup_example_nav_query(nav_query)
    
    crowd_system, _ := crowd.crowd_create(20, 3.0, nav_query)
    defer crowd.crowd_destroy(crowd_system)
    
    // Configure multiple obstacle avoidance quality levels
    low_quality := crowd.obstacle_avoidance_params_create_low_quality()
    medium_quality := crowd.obstacle_avoidance_params_create_medium_quality()
    high_quality := crowd.obstacle_avoidance_params_create_high_quality()
    
    crowd.crowd_set_obstacle_avoidance_params(crowd_system, 0, &low_quality)
    crowd.crowd_set_obstacle_avoidance_params(crowd_system, 1, &medium_quality)
    crowd.crowd_set_obstacle_avoidance_params(crowd_system, 2, &high_quality)
    
    // Create agents with different configurations
    agents := make([]nav_recast.Agent_Id, 6)
    defer delete(agents)
    
    // Group 1: Low-priority background agents (low quality avoidance)
    for i in 0..<2 {
        params := crowd.agent_params_create_civilian()
        params.obstacle_avoidance_type = 0  // Low quality
        params.max_speed = 1.5
        
        pos := [3]f32{f32(i * 2), 0, 0}
        agents[i], _ = crowd.crowd_add_agent(crowd_system, pos, &params)
    }
    
    // Group 2: Medium-priority agents (medium quality avoidance)
    for i in 2..<4 {
        params := crowd.agent_params_create_soldier()
        params.obstacle_avoidance_type = 1  // Medium quality
        
        pos := [3]f32{f32(i * 2), 0, 2}
        agents[i], _ = crowd.crowd_add_agent(crowd_system, pos, &params)
    }
    
    // Group 3: High-priority VIP agents (high quality avoidance)
    for i in 4..<6 {
        params := crowd.agent_params_create_soldier()
        params.obstacle_avoidance_type = 2  // High quality
        params.max_speed = 4.0
        params.separation_weight = 3.0  // Strong separation
        
        pos := [3]f32{f32(i * 2), 0, 4}
        agents[i], _ = crowd.crowd_add_agent(crowd_system, pos, &params)
    }
    
    fmt.printf("Created %d agents with different priority levels\n", len(agents))
    
    // Configure query filters for different agent types
    civilian_filter := crowd.crowd_get_editable_filter(crowd_system, 0)
    if civilian_filter != nil {
        // Civilians avoid certain areas
        civilian_filter.area_cost[1] = 5.0  // Avoid area type 1
    }
    
    military_filter := crowd.crowd_get_editable_filter(crowd_system, 1)
    if military_filter != nil {
        // Military units can use restricted areas
        military_filter.area_cost[1] = 1.0  // Normal cost for area type 1
    }
    
    // Set different targets for each group
    target_ref := nav_recast.Poly_Ref(1)
    
    // Civilians move to safe zone
    for i in 0..<2 {
        crowd.crowd_request_move_target(crowd_system, agents[i], target_ref, {20, 0, 0})
    }
    
    // Soldiers move to objective
    for i in 2..<4 {
        crowd.crowd_request_move_target(crowd_system, agents[i], target_ref, {15, 0, 10})
    }
    
    // VIPs move to extraction point with escort formation
    for i in 4..<6 {
        offset := f32(i - 4) * 2.0 - 1.0  // -1, 1 for formation
        crowd.crowd_request_move_target(crowd_system, agents[i], target_ref, {25, 0, 5 + offset})
    }
    
    // Run advanced simulation with detailed monitoring
    dt := f32(1.0/60.0)
    collision_count := 0
    
    for frame in 0..<600 {  // 10 seconds
        crowd.crowd_update(crowd_system, dt)
        
        // Monitor for collisions and inefficient paths
        if frame % 60 == 0 {
            fmt.printf("\n--- Frame %d ---\n", frame)
            
            for i, agent_id in agents {
                agent := crowd.crowd_get_agent(crowd_system, agent_id)
                if agent != nil {
                    neighbor_count := crowd.agent_get_neighbor_count(agent)
                    corner_count := crowd.agent_get_corner_count(agent)
                    
                    fmt.printf("Agent %d: neighbors=%d corners=%d\n", i, neighbor_count, corner_count)
                    
                    // Check for potential collisions
                    for j in 0..<neighbor_count {
                        neighbor, found := crowd.agent_get_neighbor(agent, j)
                        if found && neighbor.distance < 1.0 {
                            collision_count += 1
                        }
                    }
                }
            }
        }
    }
    
    fmt.printf("\nAdvanced simulation completed\n")
    fmt.printf("Total close encounters: %d\n", collision_count)
    
    // Demonstrate dynamic reconfiguration
    fmt.println("\nReconfiguring agents for emergency evacuation...")
    
    // Switch all agents to high-priority emergency mode
    emergency_params := crowd.obstacle_avoidance_params_create_high_quality()
    emergency_params.weight_des_vel = 3.0  // Stronger goal seeking
    emergency_params.separation_weight = 2.0  // Reduce separation for faster movement
    
    crowd.crowd_set_obstacle_avoidance_params(crowd_system, 3, &emergency_params)
    
    // Update all agents to use emergency parameters
    for agent_id in agents {
        agent := crowd.crowd_get_agent(crowd_system, agent_id)
        if agent != nil {
            // In a real implementation, you would update agent parameters
            // agent.params.obstacle_avoidance_type = 3
            
            // Set emergency evacuation target
            crowd.crowd_request_move_target(crowd_system, agent_id, target_ref, {0, 0, 0})
        }
    }
    
    fmt.println("Emergency evacuation configured")
}

// Example of integrating crowd with game systems
crowd_game_integration_example :: proc() {
    fmt.println("\n=== DetourCrowd Game Integration Example ===")
    
    nav_query := create_example_nav_query()
    defer cleanup_example_nav_query(nav_query)
    
    crowd_system, _ := crowd.crowd_create(50, 2.0, nav_query)
    defer crowd.crowd_destroy(crowd_system)
    
    // Game entity structure
    Game_Entity :: struct {
        id:          i32,
        agent_id:    nav_recast.Agent_Id,
        entity_type: enum { Player, NPC, Enemy, Vehicle },
        health:      f32,
        team:        i32,
    }
    
    entities := make([]Game_Entity, 10)
    defer delete(entities)
    
    // Create mixed entity types
    for i in 0..<len(entities) {
        entity := &entities[i]
        entity.id = i32(i)
        entity.health = 100.0
        
        params: crowd.Dt_Crowd_Agent_Params
        pos := [3]f32{f32(i % 5) * 3, 0, f32(i / 5) * 3}
        
        switch i % 4 {
        case 0:
            entity.entity_type = .Player
            entity.team = 0
            params = crowd.agent_params_create_soldier()
            params.max_speed = 3.5
            
        case 1:
            entity.entity_type = .NPC
            entity.team = 0
            params = crowd.agent_params_create_civilian()
            
        case 2:
            entity.entity_type = .Enemy
            entity.team = 1
            params = crowd.agent_params_create_soldier()
            params.max_speed = 3.0
            
        case 3:
            entity.entity_type = .Vehicle
            entity.team = 0
            params = crowd.agent_params_create_vehicle()
        }
        
        entity.agent_id, _ = crowd.crowd_add_agent(crowd_system, pos, &params)
    }
    
    fmt.printf("Created %d game entities with crowd agents\n", len(entities))
    
    // Game simulation loop
    dt := f32(1.0/30.0)  // 30 FPS game loop
    game_time := f32(0)
    
    for tick in 0..<300 {  // 10 seconds of game time
        game_time += dt
        
        // Update crowd simulation
        crowd.crowd_update(crowd_system, dt)
        
        // Game logic updates
        for &entity in entities {
            agent := crowd.crowd_get_agent(crowd_system, entity.agent_id)
            if agent == nil do continue
            
            // Update game entity based on agent state
            pos := crowd.agent_get_position(agent)
            vel := crowd.agent_get_velocity(agent)
            
            // Example: Damage entities that move too fast (collision damage)
            speed := length(vel)
            if speed > 5.0 {
                entity.health -= 1.0
                if entity.health <= 0 {
                    fmt.printf("Entity %d destroyed by collision!\n", entity.id)
                    crowd.crowd_remove_agent(crowd_system, entity.agent_id)
                    entity.agent_id = nav_recast.Agent_Id(0)  // Mark as removed
                }
            }
            
            // Example: AI behavior based on agent state
            if entity.entity_type == .Enemy && tick % 120 == 0 {  // Every 4 seconds
                // Find nearest player
                nearest_player_pos := [3]f32{10, 0, 10}  // Mock player position
                target_ref := nav_recast.Poly_Ref(1)
                crowd.crowd_request_move_target(crowd_system, entity.agent_id, target_ref, nearest_player_pos)
            }
        }
        
        // Print status every 60 ticks (2 seconds)
        if tick % 60 == 0 {
            fmt.printf("\n--- Game Time: %.1fs ---\n", game_time)
            
            active_entities := 0
            for entity in entities {
                if entity.agent_id != nav_recast.Agent_Id(0) {
                    active_entities += 1
                }
            }
            
            stats := crowd.crowd_get_statistics(crowd_system)
            fmt.printf("Active entities: %d, Active agents: %d\n", active_entities, stats.active_agents)
        }
    }
    
    fmt.println("Game integration example completed")
}

// Helper function to create a mock navigation query
// In a real application, this would load from a navigation mesh file
create_example_nav_query :: proc() -> ^detour.Dt_Nav_Mesh_Query {
    nav_query := new(detour.Dt_Nav_Mesh_Query)
    nav_mesh := new(detour.Dt_Nav_Mesh)
    nav_query.nav_mesh = nav_mesh
    return nav_query
}

cleanup_example_nav_query :: proc(nav_query: ^detour.Dt_Nav_Mesh_Query) {
    if nav_query != nil {
        if nav_query.nav_mesh != nil {
            free(nav_query.nav_mesh)
        }
        free(nav_query)
    }
}

// Utility function for vector length
length :: proc(v: [3]f32) -> f32 {
    return math.sqrt(v.x*v.x + v.y*v.y + v.z*v.z)
}

// Main function to run all examples
run_crowd_examples :: proc() {
    crowd_basic_example()
    crowd_advanced_example() 
    crowd_game_integration_example()
}