package navigation_detour_crowd

import nav_recast "../recast"
import detour "../detour"

// Public API for DetourCrowd functionality
// This file provides a clean interface to the crowd simulation system

// Create and initialize a new crowd manager
crowd_create :: proc(max_agents: i32, max_agent_radius: f32, nav_query: ^detour.Nav_Mesh_Query) -> (^Crowd, nav_recast.Status) {
    crowd := new(Crowd)
    status := crowd_init(crowd, max_agents, max_agent_radius, nav_query)
    
    if nav_recast.status_failed(status) {
        free(crowd)
        return nil, status
    }
    
    return crowd, {.Success}
}

// Destroy crowd manager and free resources
crowd_destroy :: proc(crowd: ^Crowd) {
    if crowd == nil do return
    
    crowd_destroy(crowd)
    free(crowd)
}

// Add agent to crowd
crowd_add_agent :: proc(crowd: ^Crowd, pos: [3]f32, params: ^Crowd_Agent_Params) -> (nav_recast.Agent_Id, nav_recast.Status) {
    return crowd_add_agent(crowd, pos, params)
}

// Remove agent from crowd
crowd_remove_agent :: proc(crowd: ^Crowd, agent_id: nav_recast.Agent_Id) -> nav_recast.Status {
    return crowd_remove_agent(crowd, agent_id)
}

// Update crowd simulation
crowd_update :: proc(crowd: ^Crowd, dt: f32, debug_data: ^Crowd_Agent_Debug_Info = nil) -> nav_recast.Status {
    return crowd_update(crowd, dt, debug_data)
}

// Request agent to move to target position
crowd_request_move_target :: proc(crowd: ^Crowd, agent_id: nav_recast.Agent_Id, ref: nav_recast.Poly_Ref, pos: [3]f32) -> nav_recast.Status {
    return crowd_request_move_target(crowd, agent_id, ref, pos)
}

// Request agent to move with specified velocity
crowd_request_move_velocity :: proc(crowd: ^Crowd, agent_id: nav_recast.Agent_Id, vel: [3]f32) -> nav_recast.Status {
    return crowd_request_move_velocity(crowd, agent_id, vel)
}

// Get agent by ID
crowd_get_agent :: proc(crowd: ^Crowd, agent_id: nav_recast.Agent_Id) -> ^Crowd_Agent {
    return crowd_get_agent(crowd, agent_id)
}

// Get number of active agents
crowd_get_agent_count :: proc(crowd: ^Crowd) -> i32 {
    return crowd_get_agent_count(crowd)
}

// Get query filter for specified type
crowd_get_filter :: proc(crowd: ^Crowd, filter_type: i32) -> ^detour.Query_Filter {
    return crowd_get_filter(crowd, filter_type)
}

// Get editable query filter for specified type
crowd_get_editable_filter :: proc(crowd: ^Crowd, filter_type: i32) -> ^detour.Query_Filter {
    return crowd_get_editable_filter(crowd, filter_type)
}

// Set obstacle avoidance parameters
crowd_set_obstacle_avoidance_params :: proc(crowd: ^Crowd, index: i32, params: ^Obstacle_Avoidance_Params) -> nav_recast.Status {
    return crowd_set_obstacle_avoidance_params(crowd, index, params)
}

// Get obstacle avoidance parameters
crowd_get_obstacle_avoidance_params :: proc(crowd: ^Crowd, index: i32) -> ^Obstacle_Avoidance_Params {
    return crowd_get_obstacle_avoidance_params(crowd, index)
}

// Agent parameter helpers
agent_params_create_default :: proc() -> Crowd_Agent_Params {
    return crowd_agent_params_default()
}

// Obstacle avoidance parameter helpers
obstacle_avoidance_params_create_default :: proc() -> Obstacle_Avoidance_Params {
    return obstacle_avoidance_params_default()
}

// Agent state queries
agent_get_position :: proc(agent: ^Crowd_Agent) -> [3]f32 {
    if agent == nil do return {}
    return agent.position
}

agent_get_velocity :: proc(agent: ^Crowd_Agent) -> [3]f32 {
    if agent == nil do return {}
    return agent.velocity
}

agent_get_desired_velocity :: proc(agent: ^Crowd_Agent) -> [3]f32 {
    if agent == nil do return {}
    return agent.desired_velocity
}

agent_get_state :: proc(agent: ^Crowd_Agent) -> Crowd_Agent_State {
    if agent == nil do return .Invalid
    return agent.state
}

agent_get_target_state :: proc(agent: ^Crowd_Agent) -> Move_Request_State {
    if agent == nil do return .None
    return agent.target_state
}

agent_is_active :: proc(agent: ^Crowd_Agent) -> bool {
    if agent == nil do return false
    return agent.active
}

agent_get_corner_count :: proc(agent: ^Crowd_Agent) -> i32 {
    if agent == nil do return 0
    return agent.corner_count
}

agent_get_corner :: proc(agent: ^Crowd_Agent, index: i32) -> ([3]f32, u8, nav_recast.Poly_Ref, bool) {
    if agent == nil || index < 0 || index >= agent.corner_count {
        return {}, 0, nav_recast.INVALID_POLY_REF, false
    }
    
    return agent.corner_verts[index], agent.corner_flags[index], agent.corner_polys[index], true
}

agent_get_neighbor_count :: proc(agent: ^Crowd_Agent) -> i32 {
    if agent == nil do return 0
    return agent.neighbor_count
}

agent_get_neighbor :: proc(agent: ^Crowd_Agent, index: i32) -> (Crowd_Neighbor, bool) {
    if agent == nil || index < 0 || index >= agent.neighbor_count {
        return {}, false
    }
    
    return agent.neighbors[index], true
}

// Path corridor helpers
agent_get_path :: proc(agent: ^Crowd_Agent) -> []nav_recast.Poly_Ref {
    if agent == nil do return nil
    return agent.corridor.path[:]
}

agent_get_path_target :: proc(agent: ^Crowd_Agent) -> [3]f32 {
    if agent == nil do return {}
    return path_corridor_get_target(&agent.corridor)
}

// Local boundary helpers
agent_get_boundary_segment_count :: proc(agent: ^Crowd_Agent) -> i32 {
    if agent == nil do return 0
    return local_boundary_get_segment_count(&agent.boundary)
}

agent_get_boundary_segment :: proc(agent: ^Crowd_Agent, index: i32) -> ([6]f32, bool) {
    if agent == nil do return {}, false
    return local_boundary_get_segment(&agent.boundary, index)
}

// Utility functions for common operations

// Find nearest position on navigation mesh
crowd_find_nearest_position :: proc(crowd: ^Crowd, pos: [3]f32, filter_type: i32 = 0) -> (nav_recast.Poly_Ref, [3]f32, nav_recast.Status) {
    if crowd == nil || crowd.nav_query == nil {
        return nav_recast.INVALID_POLY_REF, {}, {.Invalid_Param}
    }
    
    filter := crowd_get_filter(crowd, filter_type)
    if filter == nil {
        return nav_recast.INVALID_POLY_REF, {}, {.Invalid_Param}
    }
    
    return detour.find_nearest_poly(crowd.nav_query, pos, crowd.agent_placement_half_extents, filter)
}

// Check if position is valid for agent placement
crowd_is_valid_position :: proc(crowd: ^Crowd, pos: [3]f32, radius: f32, filter_type: i32 = 0) -> bool {
    ref, _, status := crowd_find_nearest_position(crowd, pos, filter_type)
    if nav_recast.status_failed(status) || ref == nav_recast.INVALID_POLY_REF {
        return false
    }
    
    // Additional checks could be added here (e.g., slope, clearance)
    return true
}

// Get crowd statistics
crowd_get_statistics :: proc(crowd: ^Crowd) -> struct {
    active_agents: i32,
    max_agents: i32,
    queue_size: i32,
    max_queue_size: i32,
    pending_path_requests: i32,
    completed_path_requests: i32,
} {
    stats := struct {
        active_agents: i32,
        max_agents: i32,
        queue_size: i32,
        max_queue_size: i32,
        pending_path_requests: i32,
        completed_path_requests: i32,
    }{}
    
    if crowd == nil do return stats
    
    stats.active_agents = crowd_get_agent_count(crowd)
    stats.max_agents = crowd.max_agents
    stats.queue_size, stats.max_queue_size = path_queue_get_stats(&crowd.path_queue)
    stats.pending_path_requests = path_queue_get_pending_count(&crowd.path_queue)
    stats.completed_path_requests = path_queue_get_completed_count(&crowd.path_queue)
    
    return stats
}

// Advanced agent configuration helpers

// Create agent parameters for different agent types
agent_params_create_soldier :: proc() -> Crowd_Agent_Params {
    params := crowd_agent_params_default()
    params.radius = 0.5
    params.height = 1.8
    params.max_speed = 3.0
    params.max_acceleration = 8.0
    params.separation_weight = 2.0
    return params
}

agent_params_create_civilian :: proc() -> Crowd_Agent_Params {
    params := crowd_agent_params_default()
    params.radius = 0.4
    params.height = 1.7
    params.max_speed = 2.0
    params.max_acceleration = 6.0
    params.separation_weight = 1.5
    return params
}

agent_params_create_vehicle :: proc() -> Crowd_Agent_Params {
    params := crowd_agent_params_default()
    params.radius = 1.5
    params.height = 2.0
    params.max_speed = 8.0
    params.max_acceleration = 4.0
    params.separation_weight = 4.0
    params.collision_query_range = 20.0
    params.path_optimization_range = 50.0
    return params
}

// Preset obstacle avoidance configurations
obstacle_avoidance_params_create_low_quality :: proc() -> Obstacle_Avoidance_Params {
    params := obstacle_avoidance_params_default()
    params.grid_size = 15
    params.adaptive_divs = 5
    params.adaptive_rings = 1
    params.adaptive_depth = 3
    return params
}

obstacle_avoidance_params_create_medium_quality :: proc() -> Obstacle_Avoidance_Params {
    return obstacle_avoidance_params_default()
}

obstacle_avoidance_params_create_high_quality :: proc() -> Obstacle_Avoidance_Params {
    params := obstacle_avoidance_params_default()
    params.grid_size = 65
    params.adaptive_divs = 9
    params.adaptive_rings = 3
    params.adaptive_depth = 7
    return params
}