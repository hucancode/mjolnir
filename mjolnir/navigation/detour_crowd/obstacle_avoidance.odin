package navigation_detour_crowd

import "core:math"
import "core:slice"
import recast "../recast"

// Initialize obstacle avoidance debug data
obstacle_avoidance_debug_data_init :: proc(debug_data: ^Obstacle_Avoidance_Debug_Data, max_samples: i32) -> recast.Status {
    if debug_data == nil || max_samples <= 0 {
        return {.Invalid_Param}
    }

    debug_data.sample_velocities = make([dynamic][3]f32, 0, max_samples)
    debug_data.sample_sizes = make([dynamic]f32, 0, max_samples)
    debug_data.sample_penalties = make([dynamic]f32, 0, max_samples)
    debug_data.sample_des_vel_penalties = make([dynamic]f32, 0, max_samples)
    debug_data.sample_cur_vel_penalties = make([dynamic]f32, 0, max_samples)
    debug_data.sample_side_penalties = make([dynamic]f32, 0, max_samples)
    debug_data.sample_toi_penalties = make([dynamic]f32, 0, max_samples)
    debug_data.max_samples = max_samples

    return {.Success}
}

// Destroy obstacle avoidance debug data
obstacle_avoidance_debug_data_destroy :: proc(debug_data: ^Obstacle_Avoidance_Debug_Data) {
    if debug_data == nil do return

    delete(debug_data.sample_velocities)
    delete(debug_data.sample_sizes)
    delete(debug_data.sample_penalties)
    delete(debug_data.sample_des_vel_penalties)
    delete(debug_data.sample_cur_vel_penalties)
    delete(debug_data.sample_side_penalties)
    delete(debug_data.sample_toi_penalties)
    debug_data.max_samples = 0
}

// Reset debug data
obstacle_avoidance_debug_data_reset :: proc(debug_data: ^Obstacle_Avoidance_Debug_Data) {
    if debug_data == nil do return

    clear(&debug_data.sample_velocities)
    clear(&debug_data.sample_sizes)
    clear(&debug_data.sample_penalties)
    clear(&debug_data.sample_des_vel_penalties)
    clear(&debug_data.sample_cur_vel_penalties)
    clear(&debug_data.sample_side_penalties)
    clear(&debug_data.sample_toi_penalties)
}

// Add debug sample
obstacle_avoidance_debug_data_add_sample :: proc(debug_data: ^Obstacle_Avoidance_Debug_Data,
                                                   vel: [3]f32, size, penalty, vel_penalty,
                                                   cur_vel_penalty, side_penalty, toi_penalty: f32) -> recast.Status {
    if debug_data == nil {
        return {.Invalid_Param}
    }

    if len(debug_data.sample_velocities) >= debug_data.max_samples {
        return {.Buffer_Too_Small}
    }

    append(&debug_data.sample_velocities, vel)
    append(&debug_data.sample_sizes, size)
    append(&debug_data.sample_penalties, penalty)
    append(&debug_data.sample_des_vel_penalties, vel_penalty)
    append(&debug_data.sample_cur_vel_penalties, cur_vel_penalty)
    append(&debug_data.sample_side_penalties, side_penalty)
    append(&debug_data.sample_toi_penalties, toi_penalty)

    return {.Success}
}

// Normalize debug samples
obstacle_avoidance_debug_data_normalize_samples :: proc(debug_data: ^Obstacle_Avoidance_Debug_Data) {
    if debug_data == nil || len(debug_data.sample_penalties) == 0 do return

    // Find max penalty for normalization
    max_penalty := f32(0)
    for penalty in debug_data.sample_penalties {
        max_penalty = max(max_penalty, penalty)
    }

    if max_penalty > 1e-6 {
        // Normalize all penalties
        inv_max := 1.0 / max_penalty
        for &penalty in debug_data.sample_penalties {
            penalty *= inv_max
        }
        for &penalty in debug_data.sample_des_vel_penalties {
            penalty *= inv_max
        }
        for &penalty in debug_data.sample_cur_vel_penalties {
            penalty *= inv_max
        }
        for &penalty in debug_data.sample_side_penalties {
            penalty *= inv_max
        }
        for &penalty in debug_data.sample_toi_penalties {
            penalty *= inv_max
        }
    }
}

// Initialize obstacle avoidance query
obstacle_avoidance_query_init :: proc(query: ^Obstacle_Avoidance_Query, max_circles, max_segments: i32) -> recast.Status {
    if query == nil || max_circles <= 0 || max_segments <= 0 {
        return {.Invalid_Param}
    }

    query.max_circles = max_circles
    query.max_segments = max_segments
    query.circle_obstacles = make([dynamic]Obstacle_Circle, 0, max_circles)
    query.segment_obstacles = make([dynamic]Obstacle_Segment, 0, max_segments)

    // Initialize default parameters
    for i in 0..<DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        query.params[i] = obstacle_avoidance_params_default()
    }

    return {.Success}
}

// Destroy obstacle avoidance query
obstacle_avoidance_query_destroy :: proc(query: ^Obstacle_Avoidance_Query) {
    if query == nil do return

    delete(query.circle_obstacles)
    delete(query.segment_obstacles)
    query.circle_obstacles = nil
    query.segment_obstacles = nil
    query.max_circles = 0
    query.max_segments = 0
}

// Reset obstacles
obstacle_avoidance_query_reset :: proc(query: ^Obstacle_Avoidance_Query) {
    if query == nil do return

    clear(&query.circle_obstacles)
    clear(&query.segment_obstacles)
}

// Add circle obstacle
obstacle_avoidance_query_add_circle :: proc(query: ^Obstacle_Avoidance_Query, pos, vel, dvel: [3]f32,
                                              radius: f32, dp, np: [3]f32) -> recast.Status {
    if query == nil {
        return {.Invalid_Param}
    }

    if len(query.circle_obstacles) >= query.max_circles {
        return {.Buffer_Too_Small}
    }

    obstacle := Obstacle_Circle{
        position = pos,
        velocity = vel,
        desired_velocity = dvel,
        radius = radius,
        displacement = dp,
        next_position = np,
    }

    append(&query.circle_obstacles, obstacle)
    return {.Success}
}

// Add segment obstacle
obstacle_avoidance_query_add_segment :: proc(query: ^Obstacle_Avoidance_Query, p, q: [3]f32, touch: bool) -> recast.Status {
    if query == nil {
        return {.Invalid_Param}
    }

    if len(query.segment_obstacles) >= query.max_segments {
        return {.Buffer_Too_Small}
    }

    obstacle := Obstacle_Segment{
        start_pos = p,
        end_pos = q,
        touch = touch,
    }

    append(&query.segment_obstacles, obstacle)
    return {.Success}
}

// Sample velocity for obstacle avoidance
obstacle_avoidance_query_sample_velocity_grid :: proc(query: ^Obstacle_Avoidance_Query, pos, vel, dvel: [3]f32,
                                                        radius, max_speed: f32, params: ^Obstacle_Avoidance_Params,
                                                        debug_data: ^Obstacle_Avoidance_Debug_Data) -> [3]f32 {
    if query == nil || params == nil {
        return dvel
    }

    // Prepare parameters
    prepare_obstacle_avoidance_params(query, params)

    // Generate velocity samples on a grid
    best_vel := dvel
    best_score := math.F32_MAX
    best_time := f32(0)

    grid_size := int(params.grid_size)
    cs := max_speed * 2.0 / f32(grid_size)
    half_grid := grid_size / 2

    for y in 0..<grid_size {
        for x in 0..<grid_size {
            // Calculate sample velocity
            sample_vel := [3]f32{
                (f32(x) - f32(half_grid)) * cs,
                0,
                (f32(y) - f32(half_grid)) * cs,
            }

            // Limit speed
            vel_2d := [2]f32{sample_vel[0], sample_vel[2]}
            speed := linalg.length(vel_2d)
            if speed > max_speed {
                vel_2d = linalg.normalize(vel_2d) * max_speed
                sample_vel[0] = vel_2d.x
                sample_vel[2] = vel_2d.y
            }

            // Evaluate this velocity
            penalty, time := process_sample(query, pos, radius, vel, sample_vel, dvel,
                                              params.horiz_time, params)

            // Track debug data if requested
            if debug_data != nil {
                obstacle_avoidance_debug_data_add_sample(debug_data, sample_vel, cs, penalty,
                                                          0, 0, 0, 0)  // Detailed penalties would need calculation
            }

            // Check if this is the best sample so far
            if penalty < best_score {
                best_score = penalty
                best_vel = sample_vel
                best_time = time
            }
        }
    }

    return best_vel
}

// Sample velocity using adaptive sampling
obstacle_avoidance_query_sample_velocity_adaptive :: proc(query: ^Obstacle_Avoidance_Query, pos, vel, dvel: [3]f32,
                                                           radius, max_speed: f32, params: ^Obstacle_Avoidance_Params,
                                                           debug_data: ^Obstacle_Avoidance_Debug_Data) -> [3]f32 {
    if query == nil || params == nil {
        return dvel
    }

    // Prepare parameters
    prepare_obstacle_avoidance_params(query, params)

    // Start with desired velocity
    best_vel := dvel
    best_score := math.F32_MAX

    // Sample in rings around desired velocity
    ring_count := int(params.adaptive_rings)
    div_count := int(params.adaptive_divs)
    depth := int(params.adaptive_depth)

    for ring in 0..=ring_count {
        ring_radius := f32(ring) / f32(ring_count) * max_speed

        if ring == 0 {
            // Center sample (desired velocity)
            penalty, _ := process_sample(query, pos, radius, vel, dvel, dvel,
                                          params.horiz_time, params)
            if penalty < best_score {
                best_score = penalty
                best_vel = dvel
            }
        } else {
            // Ring samples
            sample_count := ring * div_count
            for i in 0..<sample_count {
                angle := f32(i) * 2.0 * math.PI / f32(sample_count)

                sample_vel := [3]f32{
                    dvel[0] + math.cos(angle) * ring_radius,
                    dvel[1],
                    dvel[2] + math.sin(angle) * ring_radius,
                }

                // Limit speed
                vel_2d := [2]f32{sample_vel[0], sample_vel[2]}
                speed := linalg.length(vel_2d)
                if speed > max_speed {
                    vel_2d = linalg.normalize(vel_2d) * max_speed
                    sample_vel[0] = vel_2d.x
                    sample_vel[2] = vel_2d.y
                }

                penalty, _ := process_sample(query, pos, radius, vel, sample_vel, dvel,
                                              params.horiz_time, params)

                if penalty < best_score {
                    best_score = penalty
                    best_vel = sample_vel
                }
            }
        }
    }

    return best_vel
}

// Prepare obstacle avoidance parameters
prepare_obstacle_avoidance_params :: proc(query: ^Obstacle_Avoidance_Query, params: ^Obstacle_Avoidance_Params) {
    if query == nil || params == nil do return

    query.vel_bias = params.vel_bias
    query.weight_des_vel = params.weight_des_vel
    query.weight_cur_vel = params.weight_cur_vel
    query.weight_side = params.weight_side
    query.weight_toi = params.weight_toi
    query.horiz_time = params.horiz_time
}

// Process a velocity sample and calculate penalty
process_sample :: proc(query: ^Obstacle_Avoidance_Query, pos: [3]f32, radius: f32,
                         vel, sample_vel, dvel: [3]f32, max_toi: f32,
                         params: ^Obstacle_Avoidance_Params) -> (penalty: f32, toi: f32) {

    penalty = 0
    toi = 0
    min_toi := max_toi

    // Check against circle obstacles
    for &circle in query.circle_obstacles {
        // Relative velocity
        rel_vel := sample_vel - circle.velocity

        // Relative position
        rel_pos := pos - circle.position

        // Combined radius
        combined_radius := radius + circle.radius

        // Calculate time to collision
        collision_time := ray_circle_intersect(rel_pos, rel_vel, combined_radius)

        if collision_time >= 0 && collision_time < min_toi {
            min_toi = collision_time

            // Apply penalty based on collision time
            if collision_time < 0.01 {
                penalty += params.weight_toi * 10.0  // Very high penalty for immediate collision
            } else {
                penalty += params.weight_toi / collision_time
            }
        }
    }

    // Check against segment obstacles
    for &segment in query.segment_obstacles {
        collision_time := ray_segment_intersect(pos, sample_vel, segment.start_pos, segment.end_pos, radius)

        if collision_time >= 0 && collision_time < min_toi {
            min_toi = collision_time

            if collision_time < 0.01 {
                penalty += params.weight_toi * 10.0
            } else {
                penalty += params.weight_toi / collision_time
            }
        }
    }

    // Desired velocity penalty
    dvel_diff := sample_vel - dvel
    dvel_penalty := linalg.length(dvel_diff)
    penalty += params.weight_des_vel * dvel_penalty

    // Current velocity penalty
    cvel_diff := sample_vel - vel
    cvel_penalty := linalg.length(cvel_diff)
    penalty += params.weight_cur_vel * cvel_penalty

    toi = min_toi
    return penalty, toi
}

// Ray-circle intersection test
ray_circle_intersect :: proc(pos, vel: [3]f32, radius: f32) -> f32 {
    // 2D intersection in XZ plane
    pxz := pos.xz
    vxz := vel.xz

    a := linalg.dot(vxz, vxz)
    if a < 1e-6 do return -1  // No movement

    b := 2.0 * linalg.dot(pxz, vxz)
    c := linalg.dot(pxz, pxz) - radius*radius

    discriminant := b*b - 4*a*c
    if discriminant < 0 do return -1  // No intersection

    sqrt_disc := math.sqrt(discriminant)
    t1 := (-b - sqrt_disc) / (2*a)
    t2 := (-b + sqrt_disc) / (2*a)

    if t1 >= 0 do return t1
    if t2 >= 0 do return t2
    return -1
}

// Ray-segment intersection test
ray_segment_intersect :: proc(pos, vel, seg_start, seg_end: [3]f32, radius: f32) -> f32 {
    // Simplified 2D test in XZ plane
    px, pz := pos[0], pos[2]
    vx, vz := vel[0], vel[2]
    sx, sz := seg_start[0], seg_start[2]
    ex, ez := seg_end[0], seg_end[2]

    // Segment direction
    seg_dir := [2]f32{ex - sx, ez - sz}
    seg_len := linalg.length(seg_dir)

    if seg_len < 1e-6 do return -1

    // Normalize segment direction
    seg_dir_norm := seg_dir / seg_len
    dx := seg_dir_norm.x
    dz := seg_dir_norm.y

    // Distance from point to line
    to_start_x := px - sx
    to_start_z := pz - sz

    // Project onto segment
    proj := to_start_x*dx + to_start_z*dz
    proj = recast.clamp(proj, 0, seg_len)

    // Closest point on segment
    closest_x := sx + proj*dx
    closest_z := sz + proj*dz

    // Distance to closest point
    dist_vec := [2]f32{px - closest_x, pz - closest_z}
    dist := linalg.length(dist_vec)

    if dist > radius do return -1

    // Simple time calculation (could be more sophisticated)
    vel := [2]f32{vx, vz}
    speed := linalg.length(vel)
    if speed < 1e-6 do return -1

    return (dist - radius) / speed
}

// Get obstacle avoidance parameters
obstacle_avoidance_query_get_params :: proc(query: ^Obstacle_Avoidance_Query, index: i32) -> ^Obstacle_Avoidance_Params {
    if query == nil || index < 0 || index >= DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        return nil
    }
    return &query.params[index]
}

// Set obstacle avoidance parameters
obstacle_avoidance_query_set_params :: proc(query: ^Obstacle_Avoidance_Query, index: i32, params: Obstacle_Avoidance_Params) -> recast.Status {
    if query == nil || index < 0 || index >= DT_CROWD_MAX_OBSTAVOIDANCE_PARAMS {
        return {.Invalid_Param}
    }

    query.params[index] = params
    return {.Success}
}
