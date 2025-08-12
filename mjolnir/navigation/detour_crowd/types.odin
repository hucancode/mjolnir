package navigation_detour_crowd

import recast "../recast"
import detour "../detour"

// Maximum number of neighbors considered for steering
DT_CROWD_MAX_NEIGHBORS :: 6

// Maximum number of corners in path lookahead
DT_CROWD_MAX_CORNERS :: 4

// Maximum obstacle avoidance parameter sets
DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS :: 8

// Maximum query filter types
DT_CROWD_MAX_QUERY_FILTER_TYPE :: 16

// Maximum velocity samples for obstacle avoidance
DT_MAX_PATTERN_DIVS :: 32
DT_MAX_PATTERN_RINGS :: 4

// Agent states
Crowd_Agent_State :: enum u8 {
    Invalid  = 0,
    Walking  = 1,
    Off_Mesh = 2,
}

// Movement request states
Move_Request_State :: enum u8 {
    None                = 0,
    Failed              = 1,
    Valid               = 2,
    Requesting          = 3,
    Waiting_For_Queue   = 4,
    Waiting_For_Path    = 5,
    Velocity            = 6,
}

// Agent update flags
Update_Flags :: enum u8 {
    Anticipate_Turns      = 1,
    Obstacle_Avoidance    = 2,
    Separation           = 4,
    Optimize_Vis         = 8,
    Optimize_Topo        = 16,
}

// Crowd neighbor information
Crowd_Neighbor :: struct {
    agent_index: i32,    // Index of the neighbor agent
    distance:    f32,    // Distance to the neighbor
}

// Agent configuration parameters
Crowd_Agent_Params :: struct {
    radius:                   f32,    // Agent radius [>= 0]
    height:                   f32,    // Agent height [> 0]
    max_acceleration:         f32,    // Maximum acceleration [>= 0]
    max_speed:                f32,    // Maximum speed [>= 0]
    collision_query_range:    f32,    // Collision detection range [> 0]
    path_optimization_range:  f32,    // Path visibility optimization range [> 0]
    separation_weight:        f32,    // Separation force weight [>= 0]
    update_flags:             Update_Flags,  // Behavior flags
    obstacle_avoidance_type:  u8,     // Avoidance configuration index
    query_filter_type:        u8,     // Query filter index
    user_data:                rawptr, // User-defined data
}

// Path corridor for agent navigation
Path_Corridor :: struct {
    position:     [3]f32,                      // Current corridor position
    target:       [3]f32,                      // Target position
    path:         [dynamic]recast.Poly_Ref,  // Polygon path
    max_path:     i32,                         // Maximum path length
}

// Local boundary for agent movement
Local_Boundary :: struct {
    center:       [3]f32,              // Center of boundary area
    segments:     [dynamic][6]f32,     // Boundary segments [p0x,p0y,p0z,p1x,p1y,p1z]
    polys:        [dynamic]recast.Poly_Ref,  // Boundary polygons
    max_segs:     i32,                 // Maximum segments
}

// Obstacle circle for avoidance
Obstacle_Circle :: struct {
    position:          [3]f32,  // Position of obstacle
    velocity:          [3]f32,  // Velocity of obstacle
    desired_velocity:  [3]f32,  // Desired velocity
    radius:            f32,     // Obstacle radius
    displacement:      [3]f32,  // Displacement for side selection
    next_position:     [3]f32,  // Next position for side selection
}

// Obstacle segment for avoidance
Obstacle_Segment :: struct {
    start_pos:  [3]f32,  // Segment start point
    end_pos:    [3]f32,  // Segment end point
    touch:      bool,    // True if obstacle touches agent
}

// Obstacle avoidance parameters
Obstacle_Avoidance_Params :: struct {
    vel_bias:        f32,  // Velocity bias factor
    weight_des_vel:  f32,  // Desired velocity weight
    weight_cur_vel:  f32,  // Current velocity weight
    weight_side:     f32,  // Side preference weight
    weight_toi:      f32,  // Time of impact weight
    horiz_time:      f32,  // Prediction horizon time
    grid_size:       u8,   // Velocity sample grid size
    adaptive_divs:   u8,   // Adaptive sampling divisions
    adaptive_rings:  u8,   // Adaptive sampling rings
    adaptive_depth:  u8,   // Adaptive sampling depth
}

// Debug data for obstacle avoidance
Obstacle_Avoidance_Debug_Data :: struct {
    sample_velocities:       [dynamic][3]f32,  // Sample velocities
    sample_sizes:            [dynamic]f32,     // Sample sizes
    sample_penalties:        [dynamic]f32,     // Total penalties
    sample_des_vel_penalties: [dynamic]f32,    // Desired velocity penalties
    sample_cur_vel_penalties: [dynamic]f32,    // Current velocity penalties
    sample_side_penalties:   [dynamic]f32,     // Side preference penalties
    sample_toi_penalties:    [dynamic]f32,     // Time of impact penalties
    max_samples:             i32,              // Maximum sample capacity
}

// Obstacle avoidance query system
Obstacle_Avoidance_Query :: struct {
    max_circles:       i32,                                              // Maximum circles
    max_segments:      i32,                                              // Maximum segments
    vel_bias:          f32,                                              // Velocity bias
    weight_des_vel:    f32,                                              // Desired velocity weight
    weight_cur_vel:    f32,                                              // Current velocity weight
    weight_side:       f32,                                              // Side preference weight
    weight_toi:        f32,                                              // Time of impact weight
    horiz_time:        f32,                                              // Prediction horizon
    circle_obstacles:  [dynamic]Obstacle_Circle,                      // Circle obstacles
    segment_obstacles: [dynamic]Obstacle_Segment,                     // Segment obstacles
    params:            [DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS]Obstacle_Avoidance_Params, // Parameter sets
}

// Proximity grid for spatial queries
Proximity_Grid :: struct {
    max_items:   i32,                     // Maximum items in grid
    cell_size:   f32,                     // Grid cell size
    inv_cell_size: f32,                   // Inverse cell size for fast division
    bounds:      [4]f32,                  // Grid bounds [minx, miny, maxx, maxy]
    pool:        [dynamic]u16,            // Item pool
    buckets:     [dynamic]u16,            // Grid buckets (hash table)
    hash_size:   i32,                     // Hash table size
}

// Path queue reference
Path_Queue_Ref :: distinct u32

// Path query state
Path_Query :: struct {
    ref:         Path_Queue_Ref,       // Queue reference
    start_ref:   recast.Poly_Ref,       // Start polygon
    end_ref:     recast.Poly_Ref,       // End polygon
    start_pos:   [3]f32,                  // Start position
    end_pos:     [3]f32,                  // End position
    status:      recast.Status,         // Query status
    keep_alive:  i32,                     // Keep alive counter
    filter:      ^detour.Query_Filter, // Query filter
}

// Path queue for asynchronous pathfinding
Path_Queue :: struct {
    max_path_size:  i32,                           // Maximum path size
    max_search_nodes: i32,                         // Maximum search nodes
    next_handle:    u32,                           // Next handle counter
    max_queue:      i32,                           // Maximum queue size
    queue:          [dynamic]Path_Query,        // Query queue
    nav_query:      ^detour.Nav_Mesh_Query,     // Navigation mesh query
}

// Agent animation state
Crowd_Agent_Animation :: struct {
    active:     bool,                  // Animation active flag
    init_pos:   [3]f32,               // Initial position
    start_pos:  [3]f32,               // Start position
    end_pos:    [3]f32,               // End position
    poly_ref:   recast.Poly_Ref,    // Polygon reference
    t:          f32,                  // Current time [0-1]
    t_max:      f32,                  // Maximum time
}

// Debug information for agents
Crowd_Agent_Debug_Info :: struct {
    agent_index:  i32,                                      // Agent index
    opt_start:    [3]f32,                                   // Optimization start
    opt_end:      [3]f32,                                   // Optimization end
    vod:          ^Obstacle_Avoidance_Debug_Data,        // Avoidance debug data
}

// Main crowd agent structure
Crowd_Agent :: struct {
    // Status and configuration
    active:       bool,                                     // Agent active flag
    state:        Crowd_Agent_State,                     // Current state
    partial:      bool,                                     // Partial path flag
    params:       Crowd_Agent_Params,                    // Agent parameters

    // Path and navigation
    corridor:     Path_Corridor,                         // Path corridor
    boundary:     Local_Boundary,                        // Local boundary
    topology_opt_time: f32,                                 // Time since topology optimization

    // Neighbors
    neighbors:    [DT_CROWD_MAX_NEIGHBORS]Crowd_Neighbor, // Known neighbors
    neighbor_count: i32,                                    // Number of neighbors

    // Motion state
    position:     [3]f32,                                   // Current position
    displacement: [3]f32,                                   // Displacement accumulator
    desired_velocity: [3]f32,                               // Desired velocity
    new_velocity: [3]f32,                                   // Obstacle-adjusted velocity
    velocity:     [3]f32,                                   // Actual velocity
    desired_speed: f32,                                     // Desired speed

    // Path corners
    corner_verts: [DT_CROWD_MAX_CORNERS][3]f32,             // Corner positions
    corner_flags: [DT_CROWD_MAX_CORNERS]u8,                 // Corner flags
    corner_polys: [DT_CROWD_MAX_CORNERS]recast.Poly_Ref,  // Corner polygons
    corner_count: i32,                                      // Number of corners

    // Target state
    target_state:     Move_Request_State,                // Target request state
    target_ref:       recast.Poly_Ref,                    // Target polygon
    target_pos:       [3]f32,                               // Target position (or velocity)
    target_path_ref:  Path_Queue_Ref,                    // Path queue reference
    target_replan:    bool,                                 // Replanning flag
    target_replan_time: f32,                                // Time since last replan
}

// Main crowd management system
Crowd :: struct {
    // Core configuration
    max_agents:        i32,                                 // Maximum agents
    max_agent_radius:  f32,                                 // Maximum agent radius

    // Agent management
    agents:            []Crowd_Agent,                    // Agent pool
    active_agents:     [dynamic]^Crowd_Agent,            // Active agent pointers
    agent_animations:  []Crowd_Agent_Animation,          // Agent animations

    // Path management
    path_queue:        Path_Queue,                       // Asynchronous pathfinding
    path_result:       [dynamic]recast.Poly_Ref,          // Temporary path buffer
    max_path_result:   i32,                                 // Maximum path result size

    // Obstacle avoidance
    obstacle_query:    ^Obstacle_Avoidance_Query,        // Obstacle avoidance system
    obstacle_params:   [DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS]Obstacle_Avoidance_Params,

    // Spatial queries
    proximity_grid:    ^Proximity_Grid,                  // Spatial partitioning

    // Query filters
    filters:           [DT_CROWD_MAX_QUERY_FILTER_TYPE]detour.Query_Filter,

    // Navigation mesh
    nav_query:         ^detour.Nav_Mesh_Query,           // Navigation queries

    // Configuration
    agent_placement_half_extents: [3]f32,                   // Agent placement bounds
    velocity_sample_count: i32,                             // Velocity samples
}

// Default parameters
crowd_agent_params_default :: proc() -> Crowd_Agent_Params {
    return {
        radius = 0.6,
        height = 2.0,
        max_acceleration = 8.0,
        max_speed = 3.5,
        collision_query_range = 12.0,
        path_optimization_range = 30.0,
        separation_weight = 2.0,
        update_flags = {.Anticipate_Turns, .Obstacle_Avoidance, .Separation, .Optimize_Vis},
        obstacle_avoidance_type = 3,
        query_filter_type = 0,
        user_data = nil,
    }
}

obstacle_avoidance_params_default :: proc() -> Obstacle_Avoidance_Params {
    return {
        vel_bias = 0.4,
        weight_des_vel = 2.0,
        weight_cur_vel = 0.75,
        weight_side = 0.75,
        weight_toi = 2.5,
        horiz_time = 2.5,
        grid_size = 33,
        adaptive_divs = 7,
        adaptive_rings = 2,
        adaptive_depth = 5,
    }
}
