package navigation_detour_crowd

import "core:math"
import "core:slice"
import nav_recast "../recast"
import detour "../detour"

// Initialize crowd system
dt_crowd_init :: proc(crowd: ^Dt_Crowd, max_agents: i32, max_agent_radius: f32, 
                     nav_query: ^detour.Dt_Nav_Mesh_Query) -> nav_recast.Status {
    if crowd == nil || max_agents <= 0 || max_agent_radius <= 0 || nav_query == nil {
        return {.Invalid_Param}
    }
    
    crowd.max_agents = max_agents
    crowd.max_agent_radius = max_agent_radius
    crowd.nav_query = nav_query
    
    // Allocate agent arrays
    crowd.agents = make([]Dt_Crowd_Agent, max_agents)
    crowd.agent_animations = make([]Dt_Crowd_Agent_Animation, max_agents)
    crowd.active_agents = make([dynamic]^Dt_Crowd_Agent, 0, max_agents)
    
    // Initialize agents as inactive
    for &agent in crowd.agents {
        agent.active = false
        dt_path_corridor_init(&agent.corridor, 256)
        dt_local_boundary_init(&agent.boundary, 16)
    }
    
    // Initialize path queue
    crowd.max_path_result = 256
    crowd.path_result = make([dynamic]nav_recast.Poly_Ref, 0, crowd.max_path_result)
    path_queue_status := dt_path_queue_init(&crowd.path_queue, 256, 2048, nav_query)
    if nav_recast.status_failed(path_queue_status) {
        return path_queue_status
    }
    
    // Initialize obstacle avoidance
    crowd.obstacle_query = new(Dt_Obstacle_Avoidance_Query)
    obstacle_status := dt_obstacle_avoidance_query_init(crowd.obstacle_query, max_agents * 2, max_agents * 4)
    if nav_recast.status_failed(obstacle_status) {
        return obstacle_status
    }
    
    // Initialize default obstacle avoidance parameters
    for i in 0..<DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        crowd.obstacle_params[i] = dt_obstacle_avoidance_params_default()
    }
    
    // Initialize proximity grid
    crowd.proximity_grid = new(Dt_Proximity_Grid)
    grid_status := dt_proximity_grid_init(crowd.proximity_grid, max_agents, max_agent_radius * 2.0)
    if nav_recast.status_failed(grid_status) {
        return grid_status
    }
    
    // Initialize query filters
    for &filter in crowd.filters {
        detour.dt_query_filter_init(&filter)
    }
    
    // Default configuration
    crowd.agent_placement_half_extents = {2, 4, 2}
    crowd.velocity_sample_count = 40
    
    return {.Success}
}

// Destroy crowd system
dt_crowd_destroy :: proc(crowd: ^Dt_Crowd) {
    if crowd == nil do return
    
    // Cleanup agents
    if crowd.agents != nil {
        for &agent in crowd.agents {
            dt_path_corridor_destroy(&agent.corridor)
            dt_local_boundary_destroy(&agent.boundary)
        }
        delete(crowd.agents)
    }
    
    delete(crowd.agent_animations)
    delete(crowd.active_agents)
    delete(crowd.path_result)
    
    // Cleanup subsystems
    dt_path_queue_destroy(&crowd.path_queue)
    
    if crowd.obstacle_query != nil {
        dt_obstacle_avoidance_query_destroy(crowd.obstacle_query)
        free(crowd.obstacle_query)
    }
    
    if crowd.proximity_grid != nil {
        dt_proximity_grid_destroy(crowd.proximity_grid)
        free(crowd.proximity_grid)
    }
    
    crowd.max_agents = 0
    crowd.nav_query = nil
}

// Add agent to crowd
dt_crowd_add_agent :: proc(crowd: ^Dt_Crowd, pos: [3]f32, params: ^Dt_Crowd_Agent_Params) -> (nav_recast.Agent_Id, nav_recast.Status) {
    if crowd == nil || params == nil {
        return nav_recast.Agent_Id(0), {.Invalid_Param}
    }
    
    // Find free agent slot
    agent_idx := -1
    for i in 0..<len(crowd.agents) {
        if !crowd.agents[i].active {
            agent_idx = i
            break
        }
    }
    
    if agent_idx == -1 {
        return nav_recast.Agent_Id(0), {.Out_Of_Memory}
    }
    
    agent := &crowd.agents[agent_idx]
    
    // Find nearest polygon for starting position
    nearest_ref, nearest_pos, status := detour.dt_find_nearest_poly(
        crowd.nav_query, pos, crowd.agent_placement_half_extents, &crowd.filters[params.query_filter_type]
    )
    
    if nav_recast.status_failed(status) || nearest_ref == nav_recast.INVALID_POLY_REF {
        return nav_recast.Agent_Id(0), {.Invalid_Param}
    }
    
    // Initialize agent
    agent.active = true
    agent.state = .Walking
    agent.partial = false
    agent.params = params^
    
    // Set initial position and state
    agent.position = nearest_pos
    agent.displacement = {}
    agent.desired_velocity = {}
    agent.new_velocity = {}
    agent.velocity = {}
    agent.desired_speed = 0
    
    // Reset path corridor to starting position
    dt_path_corridor_reset(&agent.corridor, nearest_ref, nearest_pos)
    
    // Reset boundary
    dt_local_boundary_reset(&agent.boundary)
    
    // Reset neighbors
    agent.neighbor_count = 0
    
    // Reset corners
    agent.corner_count = 0
    
    // Reset target state
    agent.target_state = .None
    agent.target_ref = nav_recast.INVALID_POLY_REF
    agent.target_pos = {}
    agent.target_path_ref = Dt_Path_Queue_Ref(0)
    agent.target_replan = false
    agent.target_replan_time = 0
    
    agent.topology_opt_time = 0
    
    // Add to active agents list
    append(&crowd.active_agents, agent)
    
    return nav_recast.Agent_Id(agent_idx + 1), {.Success}  // Agent ID is 1-based
}

// Remove agent from crowd
dt_crowd_remove_agent :: proc(crowd: ^Dt_Crowd, agent_id: nav_recast.Agent_Id) -> nav_recast.Status {
    if crowd == nil {
        return {.Invalid_Param}
    }
    
    agent_idx := int(agent_id) - 1  // Convert to 0-based index
    if agent_idx < 0 || agent_idx >= len(crowd.agents) {
        return {.Invalid_Param}
    }
    
    agent := &crowd.agents[agent_idx]
    if !agent.active {
        return {.Invalid_Param}
    }
    
    // Cancel any pending path requests
    if agent.target_path_ref != Dt_Path_Queue_Ref(0) {
        dt_path_queue_cancel_request(&crowd.path_queue, agent.target_path_ref)
    }
    
    // Mark agent as inactive
    agent.active = false
    
    // Remove from active agents list
    for i, active_agent in crowd.active_agents {
        if active_agent == agent {
            ordered_remove(&crowd.active_agents, i)
            break
        }
    }
    
    return {.Success}
}

// Update crowd simulation
dt_crowd_update :: proc(crowd: ^Dt_Crowd, dt: f32, debug_data: ^Dt_Crowd_Agent_Debug_Info) -> nav_recast.Status {
    if crowd == nil || dt <= 0 {
        return {.Invalid_Param}
    }
    
    // Update path queue
    dt_path_queue_update(&crowd.path_queue, 8)
    
    // Update movement requests
    dt_crowd_update_move_request(crowd, dt)
    
    // Update topology optimization
    dt_crowd_update_topology_optimization(crowd, dt)
    
    // Check path validity
    dt_crowd_check_path_validity(crowd, dt)
    
    // Build proximity grid
    dt_crowd_build_proximity_grid(crowd)
    
    // Find neighbors
    dt_crowd_find_neighbors(crowd)
    
    // Find next corner for each agent
    dt_crowd_find_corners(crowd)
    
    // Trigger off-mesh connections
    dt_crowd_trigger_off_mesh_connections(crowd)
    
    // Calculate steering
    dt_crowd_calculate_steering(crowd, dt)
    
    // Velocity planning (obstacle avoidance)
    dt_crowd_plan_velocity(crowd, dt, debug_data)
    
    // Integrate
    dt_crowd_integrate(crowd, dt)
    
    // Handle collisions
    dt_crowd_handle_collisions(crowd)
    
    return {.Success}
}

// Request agent to move to target
dt_crowd_request_move_target :: proc(crowd: ^Dt_Crowd, agent_id: nav_recast.Agent_Id, 
                                    ref: nav_recast.Poly_Ref, pos: [3]f32) -> nav_recast.Status {
    if crowd == nil {
        return {.Invalid_Param}
    }
    
    agent_idx := int(agent_id) - 1
    if agent_idx < 0 || agent_idx >= len(crowd.agents) {
        return {.Invalid_Param}
    }
    
    agent := &crowd.agents[agent_idx]
    if !agent.active {
        return {.Invalid_Param}
    }
    
    if ref == nav_recast.INVALID_POLY_REF {
        return {.Invalid_Param}
    }
    
    // Set target state
    agent.target_ref = ref
    agent.target_pos = pos
    agent.target_replan = false
    agent.target_replan_time = 0
    
    // Cancel previous path request
    if agent.target_path_ref != Dt_Path_Queue_Ref(0) {
        dt_path_queue_cancel_request(&crowd.path_queue, agent.target_path_ref)
        agent.target_path_ref = Dt_Path_Queue_Ref(0)
    }
    
    // If target is close, set directly
    if dt_path_corridor_get_first_poly(&agent.corridor) == ref {
        agent.target_state = .Valid
        dt_path_corridor_move_target(&agent.corridor, pos, crowd.nav_query, &crowd.filters[agent.params.query_filter_type])
    } else {
        // Request path computation
        start_ref := dt_path_corridor_get_first_poly(&agent.corridor)
        
        path_ref, request_status := dt_path_queue_request(&crowd.path_queue, start_ref, ref,
                                                         agent.position, pos, &crowd.filters[agent.params.query_filter_type])
        
        if nav_recast.status_succeeded(request_status) {
            agent.target_path_ref = path_ref
            agent.target_state = .Requesting
        } else {
            agent.target_state = .Failed
        }
    }
    
    return {.Success}
}

// Request agent to move with velocity
dt_crowd_request_move_velocity :: proc(crowd: ^Dt_Crowd, agent_id: nav_recast.Agent_Id, vel: [3]f32) -> nav_recast.Status {
    if crowd == nil {
        return {.Invalid_Param}
    }
    
    agent_idx := int(agent_id) - 1
    if agent_idx < 0 || agent_idx >= len(crowd.agents) {
        return {.Invalid_Param}
    }
    
    agent := &crowd.agents[agent_idx]
    if !agent.active {
        return {.Invalid_Param}
    }
    
    // Cancel path request
    if agent.target_path_ref != Dt_Path_Queue_Ref(0) {
        dt_path_queue_cancel_request(&crowd.path_queue, agent.target_path_ref)
        agent.target_path_ref = Dt_Path_Queue_Ref(0)
    }
    
    // Set velocity target
    agent.target_state = .Velocity
    agent.target_pos = vel  // Store velocity in target_pos
    agent.target_ref = nav_recast.INVALID_POLY_REF
    
    return {.Success}
}

// Get agent by ID
dt_crowd_get_agent :: proc(crowd: ^Dt_Crowd, agent_id: nav_recast.Agent_Id) -> ^Dt_Crowd_Agent {
    if crowd == nil {
        return nil
    }
    
    agent_idx := int(agent_id) - 1
    if agent_idx < 0 || agent_idx >= len(crowd.agents) {
        return nil
    }
    
    agent := &crowd.agents[agent_idx]
    if !agent.active {
        return nil
    }
    
    return agent
}

// Get agent count
dt_crowd_get_agent_count :: proc(crowd: ^Dt_Crowd) -> i32 {
    if crowd == nil do return 0
    return i32(len(crowd.active_agents))
}

// Get query filter
dt_crowd_get_filter :: proc(crowd: ^Dt_Crowd, filter_type: i32) -> ^detour.Dt_Query_Filter {
    if crowd == nil || filter_type < 0 || filter_type >= DT_CROWD_MAX_QUERY_FILTER_TYPE {
        return nil
    }
    return &crowd.filters[filter_type]
}

// Get editable query filter  
dt_crowd_get_editable_filter :: proc(crowd: ^Dt_Crowd, filter_type: i32) -> ^detour.Dt_Query_Filter {
    return dt_crowd_get_filter(crowd, filter_type)
}

// Set obstacle avoidance parameters
dt_crowd_set_obstacle_avoidance_params :: proc(crowd: ^Dt_Crowd, index: i32, params: ^Dt_Obstacle_Avoidance_Params) -> nav_recast.Status {
    if crowd == nil || params == nil || index < 0 || index >= DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        return {.Invalid_Param}
    }
    
    crowd.obstacle_params[index] = params^
    return {.Success}
}

// Get obstacle avoidance parameters
dt_crowd_get_obstacle_avoidance_params :: proc(crowd: ^Dt_Crowd, index: i32) -> ^Dt_Obstacle_Avoidance_Params {
    if crowd == nil || index < 0 || index >= DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        return nil
    }
    return &crowd.obstacle_params[index]
}

// Helper function: Update movement requests
dt_crowd_update_move_request :: proc(crowd: ^Dt_Crowd, dt: f32) {
    if crowd == nil do return
    
    for &agent in crowd.active_agents {
        switch agent.target_state {
        case .Requesting:
            // Check if path is ready
            status := dt_path_queue_get_request_status(&crowd.path_queue, agent.target_path_ref)
            if nav_recast.status_succeeded(status) {
                // Get path result
                clear(&crowd.path_result)
                resize(&crowd.path_result, crowd.max_path_result)
                
                path_count, get_status := dt_path_queue_get_path_result(&crowd.path_queue, agent.target_path_ref, crowd.path_result[:])
                if nav_recast.status_succeeded(get_status) && path_count > 0 {
                    // Set new path
                    agent.target_state = .Valid
                    dt_path_corridor_reset(&agent.corridor, crowd.path_result[0], agent.position)
                    
                    // Add remaining path
                    for i in 1..<path_count {
                        append(&agent.corridor.path, crowd.path_result[i])
                    }
                    
                    dt_path_corridor_move_target(&agent.corridor, agent.target_pos, crowd.nav_query, 
                                               &crowd.filters[agent.params.query_filter_type])
                    
                    agent.partial = .Partial_Result in status
                } else {
                    agent.target_state = .Failed
                }
            } else if nav_recast.status_failed(status) {
                agent.target_state = .Failed
            }
            
        case .Valid:
            // Path is valid, nothing to do
            
        case .Velocity:
            // Using velocity control, nothing to do
            
        case .Failed:
            // Target failed, could try replanning
            
        case .None:
            // No target set
        }
    }
}

// Helper function: Update topology optimization
dt_crowd_update_topology_optimization :: proc(crowd: ^Dt_Crowd, dt: f32) {
    if crowd == nil do return
    
    OPT_TIME_THRESHOLD :: f32(0.5)  // Optimize every 0.5 seconds
    
    for &agent in crowd.active_agents {
        if .Optimize_Topo in agent.params.update_flags {
            agent.topology_opt_time += dt
            
            if agent.topology_opt_time > OPT_TIME_THRESHOLD {
                optimized, _ := dt_path_corridor_optimize_path_topology(&agent.corridor, crowd.nav_query,
                                                                       &crowd.filters[agent.params.query_filter_type])
                if optimized {
                    agent.topology_opt_time = 0
                }
            }
        }
    }
}

// Helper function: Check path validity
dt_crowd_check_path_validity :: proc(crowd: ^Dt_Crowd, dt: f32) {
    if crowd == nil do return
    
    CHECK_LOOK_AHEAD :: i32(10)
    
    for &agent in crowd.active_agents {
        valid, _ := dt_path_corridor_is_valid(&agent.corridor, CHECK_LOOK_AHEAD, crowd.nav_query,
                                            &crowd.filters[agent.params.query_filter_type])
        
        if !valid {
            // Path is invalid, try to replan
            if agent.target_state == .Valid && agent.target_ref != nav_recast.INVALID_POLY_REF {
                // Request new path
                start_ref := dt_path_corridor_get_first_poly(&agent.corridor)
                if start_ref != nav_recast.INVALID_POLY_REF {
                    path_ref, _ := dt_path_queue_request(&crowd.path_queue, start_ref, agent.target_ref,
                                                        agent.position, agent.target_pos, &crowd.filters[agent.params.query_filter_type])
                    if path_ref != Dt_Path_Queue_Ref(0) {
                        agent.target_path_ref = path_ref
                        agent.target_state = .Requesting
                        agent.target_replan = true
                        agent.target_replan_time = 0
                    }
                }
            }
        }
    }
}