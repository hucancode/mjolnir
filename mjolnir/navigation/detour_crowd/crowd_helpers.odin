package navigation_detour_crowd

import "core:math"
import "core:math/linalg"
import "core:slice"
import nav_recast "../recast"
import detour "../detour"

// Build proximity grid for spatial queries
dt_crowd_build_proximity_grid :: proc(crowd: ^Dt_Crowd) {
    if crowd == nil || crowd.proximity_grid == nil do return

    dt_proximity_grid_clear(crowd.proximity_grid)

    for i, &agent in crowd.active_agents {
        if !agent.active do continue

        agent_id := u16(i)
        pos := agent.position
        radius := agent.params.radius

        // Add agent to grid with bounding box
        dt_proximity_grid_add_item(crowd.proximity_grid, agent_id,
                                  pos[0] - radius, pos[2] - radius,
                                  pos[0] + radius, pos[2] + radius)
    }
}

// Find neighbors for each agent
dt_crowd_find_neighbors :: proc(crowd: ^Dt_Crowd) {
    if crowd == nil || crowd.proximity_grid == nil do return

    for i, &agent in crowd.active_agents {
        if !agent.active do continue

        agent.neighbor_count = 0

        if .Separation not_in agent.params.update_flags && .Obstacle_Avoidance not_in agent.params.update_flags {
            continue
        }

        // Query nearby agents
        query_range := agent.params.collision_query_range
        neighbors := make([]u16, DT_CROWD_MAX_NEIGHBORS + 1)  // +1 to avoid including self
        defer delete(neighbors)

        neighbor_count := dt_proximity_grid_query_items(crowd.proximity_grid,
                                                       agent.position[0], agent.position[2],
                                                       query_range, neighbors[:], DT_CROWD_MAX_NEIGHBORS + 1)

        // Filter and sort neighbors
        valid_neighbors: [DT_CROWD_MAX_NEIGHBORS]struct{
            agent_idx: i32,
            distance_sqr: f32,
        }
        valid_count := 0

        for j in 0..<neighbor_count {
            neighbor_idx := int(neighbors[j])
            if neighbor_idx == i do continue  // Skip self
            if neighbor_idx >= len(crowd.active_agents) do continue

            neighbor_agent := crowd.active_agents[neighbor_idx]
            if !neighbor_agent.active do continue

            // Calculate distance
            diff := neighbor_agent.position - agent.position
            dist_sqr := linalg.length2(diff)

            // Check if within range
            combined_radius := agent.params.radius + neighbor_agent.params.radius
            if dist_sqr < (query_range + combined_radius) * (query_range + combined_radius) {
                if valid_count < DT_CROWD_MAX_NEIGHBORS {
                    valid_neighbors[valid_count] = {i32(neighbor_idx), dist_sqr}
                    valid_count += 1
                }
            }
        }

        // Sort by distance
        slice.sort_by(valid_neighbors[:valid_count], proc(a, b: struct{agent_idx: i32, distance_sqr: f32}) -> bool {
            return a.distance_sqr < b.distance_sqr
        })

        // Store neighbors
        for j in 0..<min(valid_count, DT_CROWD_MAX_NEIGHBORS) {
            agent.neighbors[j] = {
                agent_index = valid_neighbors[j].agent_idx,
                distance = math.sqrt(valid_neighbors[j].distance_sqr),
            }
        }
        agent.neighbor_count = i32(min(valid_count, DT_CROWD_MAX_NEIGHBORS))
    }
}

// Find corners for each agent's path
dt_crowd_find_corners :: proc(crowd: ^Dt_Crowd) {
    if crowd == nil do return

    for &agent in crowd.active_agents {
        if !agent.active do continue

        agent.corner_count = 0

        if agent.target_state != .Valid && agent.target_state != .Velocity {
            continue
        }

        // Find corners in path corridor
        corner_verts := make([]f32, DT_CROWD_MAX_CORNERS * 3)
        defer delete(corner_verts)
        corner_flags := make([]u8, DT_CROWD_MAX_CORNERS)
        defer delete(corner_flags)
        corner_polys := make([]nav_recast.Poly_Ref, DT_CROWD_MAX_CORNERS)
        defer delete(corner_polys)

        corner_count, status := dt_path_corridor_find_corners(&agent.corridor,
                                                             corner_verts[:], corner_flags[:], corner_polys[:],
                                                             DT_CROWD_MAX_CORNERS, crowd.nav_query,
                                                             &crowd.filters[agent.params.query_filter_type])

        if nav_recast.status_succeeded(status) {
            agent.corner_count = corner_count

            // Copy corner data
            for i in 0..<corner_count {
                agent.corner_verts[i] = {
                    corner_verts[i*3 + 0],
                    corner_verts[i*3 + 1],
                    corner_verts[i*3 + 2],
                }
                agent.corner_flags[i] = corner_flags[i]
                agent.corner_polys[i] = corner_polys[i]
            }
        }
    }
}

// Trigger off-mesh connections
dt_crowd_trigger_off_mesh_connections :: proc(crowd: ^Dt_Crowd) {
    if crowd == nil do return

    for &agent in crowd.active_agents {
        if !agent.active do continue

        // Check if agent should trigger off-mesh connection
        if agent.corner_count > 0 {
            corner_flags := detour.Dt_Straight_Path_Flags(agent.corner_flags[0])
            if .Off_Mesh_Connection in corner_flags {
                // Trigger off-mesh connection
                agent.state = .Off_Mesh
                // In a full implementation, you'd handle the animation here
            }
        }
    }
}

// Calculate steering for each agent
dt_crowd_calculate_steering :: proc(crowd: ^Dt_Crowd, dt: f32) {
    if crowd == nil do return

    for &agent in crowd.active_agents {
        if !agent.active do continue

        agent.desired_velocity = {}
        agent.desired_speed = 0

        if agent.target_state == .Velocity {
            // Direct velocity control
            agent.desired_velocity = agent.target_pos  // target_pos stores velocity
            agent.desired_speed = linalg.length(agent.desired_velocity.xz)

        } else if agent.target_state == .Valid && agent.corner_count > 0 {
            // Path following
            target_pos := agent.corner_verts[0]

            // Calculate direction to next corner
            dir := target_pos.xz - agent.position.xz
            distance := linalg.length(dir)

            if distance > 0.01 {
                // Normalize direction
                dir_norm := dir / distance
                dx := dir_norm.x
                dz := dir_norm.y

                // Set desired velocity toward target
                agent.desired_speed = agent.params.max_speed

                // Slow down when approaching target
                slowdown_distance := agent.params.radius * 4.0
                if distance < slowdown_distance {
                    agent.desired_speed *= distance / slowdown_distance
                    agent.desired_speed = max(agent.desired_speed, agent.params.max_speed * 0.1)
                }

                agent.desired_velocity = {
                    dx * agent.desired_speed,
                    0,
                    dz * agent.desired_speed,
                }

                // Anticipate turns
                if .Anticipate_Turns in agent.params.update_flags && agent.corner_count > 1 {
                    next_corner := agent.corner_verts[1]

                    // Calculate turn direction
                    turn_dir := next_corner.xz - target_pos.xz
                    turn_distance := linalg.length(turn_dir)

                    if turn_distance > 0.01 {
                        turn_dir_norm := turn_dir / turn_distance
                        turn_dx := turn_dir_norm.x
                        turn_dz := turn_dir_norm.y

                        // Blend with turn direction based on distance to corner
                        blend_distance := agent.params.radius * 2.0
                        if distance < blend_distance {
                            blend_factor := 1.0 - (distance / blend_distance)
                            agent.desired_velocity.x = linalg.mix(turn_dx * agent.desired_speed, dx, blend_factor)
                            agent.desired_velocity.z = linalg.mix(turn_dz * agent.desired_speed, dz, blend_factor)
                        }
                    }
                }
            }
        }
    }
}

// Plan velocity with obstacle avoidance
dt_crowd_plan_velocity :: proc(crowd: ^Dt_Crowd, dt: f32, debug_data: ^Dt_Crowd_Agent_Debug_Info) {
    if crowd == nil do return

    for i, &agent in crowd.active_agents {
        if !agent.active do continue

        agent.new_velocity = agent.desired_velocity

        if .Obstacle_Avoidance not_in agent.params.update_flags {
            continue
        }

        // Update local boundary
        dt_local_boundary_update(&agent.boundary, dt_path_corridor_get_first_poly(&agent.corridor),
                                agent.position, agent.params.collision_query_range, crowd.nav_query,
                                &crowd.filters[agent.params.query_filter_type])

        // Build obstacle list
        dt_obstacle_avoidance_query_reset(crowd.obstacle_query)

        // Add other agents as circle obstacles
        for j in 0..<agent.neighbor_count {
            neighbor_idx := agent.neighbors[j].agent_index
            if neighbor_idx >= 0 && neighbor_idx < i32(len(crowd.active_agents)) {
                neighbor := crowd.active_agents[neighbor_idx]
                if !neighbor.active do continue

                // Calculate relative position and velocity
                dt_obstacle_avoidance_query_add_circle(crowd.obstacle_query,
                                                      neighbor.position, neighbor.velocity, neighbor.desired_velocity,
                                                      neighbor.params.radius, {}, {})
            }
        }

        // Add boundary segments as obstacles
        boundary_count := dt_local_boundary_get_segment_count(&agent.boundary)
        for j in 0..<boundary_count {
            segment, has_segment := dt_local_boundary_get_segment(&agent.boundary, j)
            if has_segment {
                seg_start := [3]f32{segment[0], segment[1], segment[2]}
                seg_end := [3]f32{segment[3], segment[4], segment[5]}
                dt_obstacle_avoidance_query_add_segment(crowd.obstacle_query, seg_start, seg_end, false)
            }
        }

        // Sample velocity
        params := &crowd.obstacle_params[agent.params.obstacle_avoidance_type]

        // Choose sampling method based on grid size
        if params.grid_size > 0 {
            agent.new_velocity = dt_obstacle_avoidance_query_sample_velocity_grid(crowd.obstacle_query,
                                                                                 agent.position, agent.velocity, agent.desired_velocity,
                                                                                 agent.params.radius, agent.params.max_speed,
                                                                                 params, nil)
        } else {
            agent.new_velocity = dt_obstacle_avoidance_query_sample_velocity_adaptive(crowd.obstacle_query,
                                                                                     agent.position, agent.velocity, agent.desired_velocity,
                                                                                     agent.params.radius, agent.params.max_speed,
                                                                                     params, nil)
        }

        // Add separation force
        if .Separation in agent.params.update_flags {
            separation := dt_calculate_separation_force(&agent, crowd.active_agents[:])
            agent.new_velocity[0] += separation[0] * agent.params.separation_weight
            agent.new_velocity[2] += separation[2] * agent.params.separation_weight
        }

        // Limit velocity
        vel_2d := agent.new_velocity.xz
        speed := linalg.length(vel_2d)
        if speed > agent.params.max_speed {
            vel_2d = linalg.normalize(vel_2d) * agent.params.max_speed
            agent.new_velocity[0] = vel_2d.x
            agent.new_velocity[2] = vel_2d.y
        }
    }
}

// Integrate agent movement
dt_crowd_integrate :: proc(crowd: ^Dt_Crowd, dt: f32) {
    if crowd == nil do return

    for &agent in crowd.active_agents {
        if !agent.active do continue

        // Integrate velocity (apply acceleration constraints)
        max_delta_v := agent.params.max_acceleration * dt

        dv := agent.new_velocity - agent.velocity

        dv_len := linalg.length(dv)
        if dv_len > max_delta_v {
            dv = linalg.normalize(dv) * max_delta_v
        }

        agent.velocity += dv

        // Integrate position
        if agent.state == .Walking {
            new_pos := [3]f32{
                agent.position[0] + agent.velocity[0] * dt,
                agent.position[1] + agent.velocity[1] * dt,
                agent.position[2] + agent.velocity[2] * dt,
            }

            // Move along navigation mesh surface
            moved, _ := dt_path_corridor_move_position(&agent.corridor, new_pos, crowd.nav_query,
                                                     &crowd.filters[agent.params.query_filter_type])
            if moved {
                agent.position = dt_path_corridor_get_pos(&agent.corridor)
            }
        }
    }
}

// Handle collisions between agents
dt_crowd_handle_collisions :: proc(crowd: ^Dt_Crowd) {
    if crowd == nil do return

    // Simple collision resolution - separate overlapping agents
    for i, &agent_a in crowd.active_agents {
        if !agent_a.active do continue

        for j in i+1..<len(crowd.active_agents) {
            agent_b := crowd.active_agents[j]
            if !agent_b.active do continue

            diff := agent_b.position - agent_a.position

            dist_sqr := linalg.length2(diff)
            min_dist := agent_a.params.radius + agent_b.params.radius

            if dist_sqr < min_dist * min_dist && dist_sqr > 1e-6 {
                // Agents are overlapping, separate them
                dist := math.sqrt(dist_sqr)
                overlap := min_dist - dist

                // Separation direction
                sep_dir := diff / dist
                sep_x := sep_dir.x
                sep_z := sep_dir.z

                // Move agents apart (half distance each)
                move_dist := overlap * 0.5

                agent_a.position[0] -= sep_x * move_dist
                agent_a.position[2] -= sep_z * move_dist

                agent_b.position[0] += sep_x * move_dist
                agent_b.position[2] += sep_z * move_dist
            }
        }
    }
}

// Calculate separation force for an agent
dt_calculate_separation_force :: proc(agent: ^Dt_Crowd_Agent, agents: []^Dt_Crowd_Agent) -> [3]f32 {
    if agent == nil do return {}

    separation := [3]f32{}
    neighbor_count := 0

    for i in 0..<agent.neighbor_count {
        neighbor_idx := agent.neighbors[i].agent_index
        if neighbor_idx >= 0 && neighbor_idx < i32(len(agents)) {
            neighbor := agents[neighbor_idx]
            if !neighbor.active do continue

            dx := agent.position[0] - neighbor.position[0]
            dz := agent.position[2] - neighbor.position[2]

            dist_sqr := dx*dx + dz*dz
            min_dist := agent.params.radius + neighbor.params.radius + 0.1  // Small buffer

            if dist_sqr < min_dist * min_dist && dist_sqr > 1e-6 {
                dist := math.sqrt(dist_sqr)
                force := (min_dist - dist) / min_dist

                separation[0] += (dx / dist) * force
                separation[2] += (dz / dist) * force
                neighbor_count += 1
            }
        }
    }

    if neighbor_count > 0 {
        separation[0] /= f32(neighbor_count)
        separation[2] /= f32(neighbor_count)
    }

    return separation
}
