package navigation_detour_crowd

import "core:math"
import "core:slice"
import recast "../recast"
import detour "../detour"

// Initialize crowd system
crowd_init :: proc(crowd: ^Crowd, max_agents: i32, max_agent_radius: f32,
                     nav_query: ^detour.Nav_Mesh_Query) -> recast.Status {
    if crowd == nil || max_agents <= 0 || max_agent_radius <= 0 || nav_query == nil {
        return {.Invalid_Param}
    }

    crowd.max_agents = max_agents
    crowd.max_agent_radius = max_agent_radius
    crowd.nav_query = nav_query

    // Allocate agent arrays
    crowd.agents = make([]Crowd_Agent, max_agents)
    crowd.agent_animations = make([]Crowd_Agent_Animation, max_agents)
    crowd.active_agents = make([dynamic]^Crowd_Agent, 0, max_agents)

    // Initialize agents as inactive
    for &agent in crowd.agents {
        agent.active = false
        path_corridor_init(&agent.corridor, 256)
        local_boundary_init(&agent.boundary, 16)
    }

    // Initialize path queue
    crowd.max_path_result = 256
    crowd.path_result = make([dynamic]recast.Poly_Ref, 0, crowd.max_path_result)
    path_queue_status := path_queue_init(&crowd.path_queue, 256, 2048, nav_query)
    if recast.status_failed(path_queue_status) {
        return path_queue_status
    }

    // Initialize obstacle avoidance
    crowd.obstacle_query = new(Obstacle_Avoidance_Query)
    obstacle_status := obstacle_avoidance_query_init(crowd.obstacle_query, max_agents * 2, max_agents * 4)
    if recast.status_failed(obstacle_status) {
        return obstacle_status
    }

    // Initialize default obstacle avoidance parameters
    for i in 0..<DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        crowd.obstacle_params[i] = obstacle_avoidance_params_default()
    }

    // Initialize proximity grid
    crowd.proximity_grid = new(Proximity_Grid)
    grid_status := proximity_grid_init(crowd.proximity_grid, max_agents, max_agent_radius * 2.0)
    if recast.status_failed(grid_status) {
        return grid_status
    }

    // Initialize query filters
    for &filter in crowd.filters {
        detour.query_filter_init(&filter)
    }

    // Default configuration
    crowd.agent_placement_half_extents = {2, 4, 2}
    crowd.velocity_sample_count = 40

    return {.Success}
}

// Destroy crowd system
crowd_destroy :: proc(crowd: ^Crowd) {
    if crowd == nil do return

    // Cleanup agents
    if crowd.agents != nil {
        for &agent in crowd.agents {
            path_corridor_destroy(&agent.corridor)
            local_boundary_destroy(&agent.boundary)
        }
        delete(crowd.agents)
    }

    delete(crowd.agent_animations)
    delete(crowd.active_agents)
    delete(crowd.path_result)

    // Cleanup subsystems
    path_queue_destroy(&crowd.path_queue)

    if crowd.obstacle_query != nil {
        obstacle_avoidance_query_destroy(crowd.obstacle_query)
        free(crowd.obstacle_query)
    }

    if crowd.proximity_grid != nil {
        proximity_grid_destroy(crowd.proximity_grid)
        free(crowd.proximity_grid)
    }

    crowd.max_agents = 0
    crowd.nav_query = nil
}

// Add agent to crowd
crowd_add_agent :: proc(crowd: ^Crowd, pos: [3]f32, params: ^Crowd_Agent_Params) -> (recast.Agent_Id, recast.Status) {
    if crowd == nil || params == nil {
        return recast.Agent_Id(0), {.Invalid_Param}
    }

    // Find free agent slot
    agent_idx := -1
    for &agent, i in crowd.agents {
        if !agent.active {
            agent_idx = i
            break
        }
    }

    if agent_idx == -1 {
        return recast.Agent_Id(0), {.Out_Of_Memory}
    }

    agent := &crowd.agents[agent_idx]

    // Find nearest polygon for starting position
    nearest_ref, nearest_pos, status := detour.find_nearest_poly(
        crowd.nav_query, pos, crowd.agent_placement_half_extents, &crowd.filters[params.query_filter_type]
    )

    if recast.status_failed(status) || nearest_ref == recast.INVALID_POLY_REF {
        return recast.Agent_Id(0), {.Invalid_Param}
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
    path_corridor_reset(&agent.corridor, nearest_ref, nearest_pos)

    // Reset boundary
    local_boundary_reset(&agent.boundary)

    // Reset neighbors
    agent.neighbor_count = 0

    // Reset corners
    agent.corner_count = 0

    // Reset target state
    agent.target_state = .None
    agent.target_ref = recast.INVALID_POLY_REF
    agent.target_pos = {}
    agent.target_path_ref = Path_Queue_Ref(0)
    agent.target_replan = false
    agent.target_replan_time = 0

    agent.topology_opt_time = 0

    // Add to active agents list
    append(&crowd.active_agents, agent)

    return recast.Agent_Id(agent_idx + 1), {.Success}  // Agent ID is 1-based
}

// Remove agent from crowd
crowd_remove_agent :: proc(crowd: ^Crowd, agent_id: recast.Agent_Id) -> recast.Status {
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
    if agent.target_path_ref != Path_Queue_Ref(0) {
        path_queue_cancel_request(&crowd.path_queue, agent.target_path_ref)
    }

    // Mark agent as inactive
    agent.active = false

    // Remove from active agents list
    if idx, found := slice.linear_search(crowd.active_agents[:], agent); found {
        ordered_remove(&crowd.active_agents, idx)
    }

    return {.Success}
}

// Update crowd simulation
crowd_update :: proc(crowd: ^Crowd, dt: f32, debug_data: ^Crowd_Agent_Debug_Info) -> recast.Status {
    if crowd == nil || dt <= 0 {
        return {.Invalid_Param}
    }

    // Update path queue
    path_queue_update(&crowd.path_queue, 8)

    // Update movement requests
    crowd_update_move_request(crowd, dt)

    // Update topology optimization
    crowd_update_topology_optimization(crowd, dt)

    // Check path validity
    crowd_check_path_validity(crowd, dt)

    // Build proximity grid
    crowd_build_proximity_grid(crowd)

    // Find neighbors
    crowd_find_neighbors(crowd)

    // Find next corner for each agent
    crowd_find_corners(crowd)

    // Trigger off-mesh connections
    crowd_trigger_off_mesh_connections(crowd)

    // Calculate steering
    crowd_calculate_steering(crowd, dt)

    // Velocity planning (obstacle avoidance)
    crowd_plan_velocity(crowd, dt, debug_data)

    // Integrate
    crowd_integrate(crowd, dt)

    // Handle collisions
    crowd_handle_collisions(crowd)

    return {.Success}
}

// Request agent to move to target
crowd_request_move_target :: proc(crowd: ^Crowd, agent_id: recast.Agent_Id,
                                    ref: recast.Poly_Ref, pos: [3]f32) -> recast.Status {
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

    if ref == recast.INVALID_POLY_REF {
        return {.Invalid_Param}
    }

    // Set target state
    agent.target_ref = ref
    agent.target_pos = pos
    agent.target_replan = false
    agent.target_replan_time = 0

    // Cancel previous path request
    if agent.target_path_ref != Path_Queue_Ref(0) {
        path_queue_cancel_request(&crowd.path_queue, agent.target_path_ref)
        agent.target_path_ref = Path_Queue_Ref(0)
    }

    // If target is close, set directly
    if path_corridor_get_first_poly(&agent.corridor) == ref {
        agent.target_state = .Valid
        path_corridor_move_target(&agent.corridor, pos, crowd.nav_query, &crowd.filters[agent.params.query_filter_type])
    } else {
        // Request path computation
        start_ref := path_corridor_get_first_poly(&agent.corridor)

        path_ref, request_status := path_queue_request(&crowd.path_queue, start_ref, ref,
                                                         agent.position, pos, &crowd.filters[agent.params.query_filter_type])

        if recast.status_succeeded(request_status) {
            agent.target_path_ref = path_ref
            agent.target_state = .Requesting
        } else {
            agent.target_state = .Failed
        }
    }

    return {.Success}
}

// Request agent to move with velocity
crowd_request_move_velocity :: proc(crowd: ^Crowd, agent_id: recast.Agent_Id, vel: [3]f32) -> recast.Status {
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
    if agent.target_path_ref != Path_Queue_Ref(0) {
        path_queue_cancel_request(&crowd.path_queue, agent.target_path_ref)
        agent.target_path_ref = Path_Queue_Ref(0)
    }

    // Set velocity target
    agent.target_state = .Velocity
    agent.target_pos = vel  // Store velocity in target_pos
    agent.target_ref = recast.INVALID_POLY_REF

    return {.Success}
}

// Get agent by ID
crowd_get_agent :: proc(crowd: ^Crowd, agent_id: recast.Agent_Id) -> ^Crowd_Agent {
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
crowd_get_agent_count :: proc(crowd: ^Crowd) -> i32 {
    if crowd == nil do return 0
    return i32(len(crowd.active_agents))
}

// Get query filter
crowd_get_filter :: proc(crowd: ^Crowd, filter_type: i32) -> ^detour.Query_Filter {
    if crowd == nil || filter_type < 0 || filter_type >= DT_CROWD_MAX_QUERY_FILTER_TYPE {
        return nil
    }
    return &crowd.filters[filter_type]
}

// Get editable query filter
crowd_get_editable_filter :: proc(crowd: ^Crowd, filter_type: i32) -> ^detour.Query_Filter {
    return crowd_get_filter(crowd, filter_type)
}

// Set obstacle avoidance parameters
crowd_set_obstacle_avoidance_params :: proc(crowd: ^Crowd, index: i32, params: ^Obstacle_Avoidance_Params) -> recast.Status {
    if crowd == nil || params == nil || index < 0 || index >= DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        return {.Invalid_Param}
    }

    crowd.obstacle_params[index] = params^
    return {.Success}
}

// Get obstacle avoidance parameters
crowd_get_obstacle_avoidance_params :: proc(crowd: ^Crowd, index: i32) -> ^Obstacle_Avoidance_Params {
    if crowd == nil || index < 0 || index >= DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        return nil
    }
    return &crowd.obstacle_params[index]
}

// Helper function: Update movement requests
crowd_update_move_request :: proc(crowd: ^Crowd, dt: f32) {
    if crowd == nil do return

    for &agent in crowd.active_agents {
        switch agent.target_state {
        case .Requesting:
            // Check if path is ready
            status := path_queue_get_request_status(&crowd.path_queue, agent.target_path_ref)
            if recast.status_succeeded(status) {
                // Get path result
                clear(&crowd.path_result)
                resize(&crowd.path_result, crowd.max_path_result)

                path_count, get_status := path_queue_get_path_result(&crowd.path_queue, agent.target_path_ref, crowd.path_result[:])
                if recast.status_succeeded(get_status) && path_count > 0 {
                    // Set new path
                    agent.target_state = .Valid
                    path_corridor_reset(&agent.corridor, crowd.path_result[0], agent.position)

                    // Add remaining path
                    for i in 1..<path_count {
                        append(&agent.corridor.path, crowd.path_result[i])
                    }

                    path_corridor_move_target(&agent.corridor, agent.target_pos, crowd.nav_query,
                                               &crowd.filters[agent.params.query_filter_type])

                    agent.partial = .Partial_Result in status
                } else {
                    agent.target_state = .Failed
                }
            } else if recast.status_failed(status) {
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
crowd_update_topology_optimization :: proc(crowd: ^Crowd, dt: f32) {
    if crowd == nil do return

    OPT_TIME_THRESHOLD :: f32(0.5)  // Optimize every 0.5 seconds

    for &agent in crowd.active_agents {
        if .Optimize_Topo in agent.params.update_flags {
            agent.topology_opt_time += dt

            if agent.topology_opt_time > OPT_TIME_THRESHOLD {
                optimized, _ := path_corridor_optimize_path_topology(&agent.corridor, crowd.nav_query,
                                                                       &crowd.filters[agent.params.query_filter_type])
                if optimized {
                    agent.topology_opt_time = 0
                }
            }
        }
    }
}

// Helper function: Check path validity
crowd_check_path_validity :: proc(crowd: ^Crowd, dt: f32) {
    if crowd == nil do return

    CHECK_LOOK_AHEAD :: i32(10)

    for &agent in crowd.active_agents {
        valid, _ := path_corridor_is_valid(&agent.corridor, CHECK_LOOK_AHEAD, crowd.nav_query,
                                            &crowd.filters[agent.params.query_filter_type])

        if !valid {
            // Path is invalid, try to replan
            if agent.target_state == .Valid && agent.target_ref != recast.INVALID_POLY_REF {
                // Request new path
                start_ref := path_corridor_get_first_poly(&agent.corridor)
                if start_ref != recast.INVALID_POLY_REF {
                    path_ref, _ := path_queue_request(&crowd.path_queue, start_ref, agent.target_ref,
                                                        agent.position, agent.target_pos, &crowd.filters[agent.params.query_filter_type])
                    if path_ref != Path_Queue_Ref(0) {
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
