package navigation_detour_crowd

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import recast "../recast"
import detour "../detour"

// Build proximity grid for spatial queries
crowd_build_proximity_grid :: proc(crowd: ^Crowd) {
    if crowd == nil || crowd.proximity_grid == nil do return

    proximity_grid_clear(crowd.proximity_grid)

    for agent, active_idx in crowd.active_agents {
        if !agent.active do continue

        agent_idx := crowd_get_agent_index(crowd, agent)
        // Use the actual agent index from the main agents array, not the active agents index
        agent_id := u16(agent_idx)
        pos := agent.position
        radius := agent.params.radius

        // Add agent to grid with bounding box
        proximity_grid_add_item(crowd.proximity_grid, agent_id,
                                  pos[0] - radius, pos[2] - radius,
                                  pos[0] + radius, pos[2] + radius)
    }
}

// Find neighbors for each agent
crowd_find_neighbors :: proc(crowd: ^Crowd) {
    if crowd == nil || crowd.proximity_grid == nil do return

    for &agent in crowd.active_agents {  // Need mutable reference to update neighbor_count
        if !agent.active do continue

        agent.neighbor_count = 0

        if .Separation not_in agent.params.update_flags && .Obstacle_Avoidance not_in agent.params.update_flags {
            continue
        }

        // Get the actual agent index
        agent_idx := crowd_get_agent_index(crowd, agent)

        // Query nearby agents
        query_range := agent.params.collision_query_range
        neighbors := make([]u16, DT_CROWD_MAX_NEIGHBORS + 1)  // +1 to avoid including self
        defer delete(neighbors)

        neighbor_count := proximity_grid_query_items(crowd.proximity_grid,
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
            if neighbor_idx == int(agent_idx) do continue  // Skip self
            if neighbor_idx >= len(crowd.agents) do continue

            neighbor_agent := &crowd.agents[neighbor_idx]
            if !neighbor_agent.active do continue

            // Calculate distance using only XZ components (2D distance for navigation)
            diff_2d := [2]f32{neighbor_agent.position.x - agent.position.x, neighbor_agent.position.z - agent.position.z}
            dist_sqr := linalg.length2(diff_2d)
            
            // Check if within the collision query range
            if dist_sqr <= query_range * query_range {
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
crowd_find_corners :: proc(crowd: ^Crowd) {
    if crowd == nil do return

    for &agent in crowd.active_agents {
        if !agent.active do continue

        agent.corner_count = 0

        if agent.target_state != .Valid && agent.target_state != .Velocity {
            continue
        }
        
        // For single-polygon paths, ensure we have a proper target
        if agent.target_state == .Valid && len(agent.corridor.path) == 1 {
            // Make sure target is set properly for single-polygon case
            dist_to_target := linalg.distance(agent.corridor.target, agent.position)
            if dist_to_target < 0.1 {
                // Target is too close to current position, might be incorrectly set
                continue
            }
            // Single polygon path should still create a corner at the target
        }

        // Ensure corridor position is synchronized with agent position
        agent.corridor.position = agent.position
        
        // Find corners in path corridor
        corner_verts := make([]f32, DT_CROWD_MAX_CORNERS * 3)
        defer delete(corner_verts)
        corner_flags := make([]u8, DT_CROWD_MAX_CORNERS)
        defer delete(corner_flags)
        corner_polys := make([]recast.Poly_Ref, DT_CROWD_MAX_CORNERS)
        defer delete(corner_polys)

        corner_count, status := path_corridor_find_corners(&agent.corridor,
                                                             corner_verts[:], corner_flags[:], corner_polys[:],
                                                             DT_CROWD_MAX_CORNERS, crowd.nav_query,
                                                             &crowd.filters[agent.params.query_filter_type])

        if recast.status_succeeded(status) {
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

// Get distance to goal (matching C++ getDistanceToGoal)
get_distance_to_goal :: proc(agent: ^Crowd_Agent, default_range: f32) -> f32 {
    if agent == nil || agent.corner_count == 0 {
        return default_range
    }
    
    // Check if last corner is the end of path
    is_end_of_path := (agent.corner_flags[agent.corner_count - 1] & u8(detour.Straight_Path_Flags.End)) != 0
    if is_end_of_path {
        // Calculate 2D distance to last corner
        dx := agent.corner_verts[agent.corner_count - 1].x - agent.position.x
        dz := agent.corner_verts[agent.corner_count - 1].z - agent.position.z
        dist_2d := math.sqrt(dx*dx + dz*dz)
        return min(dist_2d, default_range)
    }
    
    return default_range
}

// Trigger off-mesh connections
crowd_trigger_off_mesh_connections :: proc(crowd: ^Crowd) {
    if crowd == nil do return

    for &agent in crowd.active_agents {
        if !agent.active do continue

        // Check if agent should trigger off-mesh connection
        if agent.corner_count > 0 {
            corner_flags := agent.corner_flags[0]
            if corner_flags & u8(detour.Straight_Path_Flags.Off_Mesh_Connection) != 0 {
                // Trigger off-mesh connection
                agent.state = .Off_Mesh
                // In a full implementation, you'd handle the animation here
            }
        }
    }
}

// Calculate steering for each agent
crowd_calculate_steering :: proc(crowd: ^Crowd, dt: f32) {
    if crowd == nil do return

    for &agent in crowd.active_agents {
        if !agent.active do continue

        agent.desired_velocity = {}
        agent.desired_speed = 0

        if agent.target_state == .Velocity {
            // Direct velocity control
            agent.desired_velocity = agent.target_pos  // target_pos stores velocity
            agent.desired_speed = linalg.length(agent.desired_velocity.xz)

        } else if agent.target_state == .Valid {
            // Path following - matching C++ implementation
            if agent.corner_count == 0 {
                // No corners - set velocity to zero (matching C++ calcStraightSteerDirection)
                agent.desired_velocity = {}
                agent.desired_speed = 0
            } else {
                // Calculate direction to first corner (matching C++ calcStraightSteerDirection)
                dir := agent.corner_verts[0] - agent.position
                dir.y = 0  // Ignore Y for 2D navigation
                dir_len := linalg.length(dir)
                
                if dir_len > 0.001 {
                    // Normalize direction
                    dir = linalg.normalize(dir)
                    
                    // Calculate speed scale for slowing down near goal
                    slow_down_radius := agent.params.radius * 2.0
                    distance_to_goal := get_distance_to_goal(agent, slow_down_radius)
                    speed_scale := min(distance_to_goal / slow_down_radius, 1.0)
                    
                    // Set desired velocity with speed scaling
                    agent.desired_speed = agent.params.max_speed
                    agent.desired_velocity = dir * (agent.desired_speed * speed_scale)
                } else {
                    agent.desired_velocity = {}
                    agent.desired_speed = 0
                }
            }
        }
    }
}

// Plan velocity with obstacle avoidance
crowd_plan_velocity :: proc(crowd: ^Crowd, dt: f32, debug_data: ^Crowd_Agent_Debug_Info) {
    if crowd == nil do return

    for &agent in crowd.active_agents {  // Need mutable reference to update new_velocity
        if !agent.active do continue

        agent.new_velocity = agent.desired_velocity

        if .Obstacle_Avoidance not_in agent.params.update_flags {
            continue
        }

        // Update local boundary
        local_boundary_update(&agent.boundary, path_corridor_get_first_poly(&agent.corridor),
                                agent.position, agent.params.collision_query_range, crowd.nav_query,
                                &crowd.filters[agent.params.query_filter_type])

        // Build obstacle list
        obstacle_avoidance_query_reset(crowd.obstacle_query)

        // Add other agents as circle obstacles
        for j in 0..<agent.neighbor_count {
            neighbor_idx := agent.neighbors[j].agent_index
            if neighbor_idx >= 0 && neighbor_idx < i32(len(crowd.agents)) {
                neighbor := &crowd.agents[neighbor_idx]
                if !neighbor.active do continue

                // Calculate relative position and velocity
                obstacle_avoidance_query_add_circle(crowd.obstacle_query,
                                                      neighbor.position, neighbor.velocity, neighbor.desired_velocity,
                                                      neighbor.params.radius, {}, {})
            }
        }

        // Add boundary segments as obstacles
        boundary_count := local_boundary_get_segment_count(&agent.boundary)
        for j in 0..<boundary_count {
            segment, has_segment := local_boundary_get_segment(&agent.boundary, j)
            if has_segment {
                seg_start := [3]f32{segment[0], segment[1], segment[2]}
                seg_end := [3]f32{segment[3], segment[4], segment[5]}
                obstacle_avoidance_query_add_segment(crowd.obstacle_query, seg_start, seg_end, false)
            }
        }

        // Sample velocity
        params := &crowd.obstacle_params[agent.params.obstacle_avoidance_type]

        // Choose sampling method based on grid size
        if params.grid_size > 0 {
            agent.new_velocity = obstacle_avoidance_query_sample_velocity_grid(crowd.obstacle_query,
                                                                                 agent.position, agent.velocity, agent.desired_velocity,
                                                                                 agent.params.radius, agent.params.max_speed,
                                                                                 params, nil)
        } else {
            agent.new_velocity = obstacle_avoidance_query_sample_velocity_adaptive(crowd.obstacle_query,
                                                                                     agent.position, agent.velocity, agent.desired_velocity,
                                                                                     agent.params.radius, agent.params.max_speed,
                                                                                     params, nil)
        }

        // Add separation force
        if .Separation in agent.params.update_flags {
            separation := calculate_separation_force(agent, crowd)
            agent.new_velocity += separation * agent.params.separation_weight
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
crowd_integrate :: proc(crowd: ^Crowd, dt: f32) {
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
            new_pos := agent.position + agent.velocity * dt

            // Move along navigation mesh surface
            moved, move_status := path_corridor_move_position(&agent.corridor, new_pos, crowd.nav_query,
                                                     &crowd.filters[agent.params.query_filter_type])
            if moved {
                // Update agent position from corridor
                agent.position = path_corridor_get_pos(&agent.corridor)
            } else {
                // If move along surface failed, just update position directly
                // This ensures agents can still move even if navmesh queries fail
                agent.position = new_pos
                agent.corridor.position = new_pos
            }
        } else if agent.state == .Invalid {
            // For agents without valid navmesh position, just integrate directly
            agent.position += agent.velocity * dt
        }
    }
}

// Handle collisions between agents
crowd_handle_collisions :: proc(crowd: ^Crowd) {
    if crowd == nil do return

    // Simple collision resolution - separate overlapping agents
    for &agent_a, i in crowd.active_agents {
        if !agent_a.active do continue

        for j in i+1..<len(crowd.active_agents) {
            agent_b := crowd.active_agents[j]  // Already a pointer
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

                sep_vec := [3]f32{sep_x, 0, sep_z} * move_dist
                agent_a.position -= sep_vec
                agent_b.position += sep_vec
            }
        }
    }
}

// Calculate separation force for an agent
calculate_separation_force :: proc(agent: ^Crowd_Agent, crowd: ^Crowd) -> [3]f32 {
    if agent == nil || crowd == nil do return {}

    separation := [3]f32{}
    neighbor_count := 0

    for i in 0..<agent.neighbor_count {
        neighbor_idx := agent.neighbors[i].agent_index
        if neighbor_idx >= 0 && neighbor_idx < i32(len(crowd.agents)) {
            neighbor := &crowd.agents[neighbor_idx]
            if !neighbor.active do continue

            diff := agent.position - neighbor.position
            dist_sqr := linalg.length2(diff.xz)
            min_dist := agent.params.radius + neighbor.params.radius + 0.1  // Small buffer

            if dist_sqr < min_dist * min_dist && dist_sqr > 1e-6 {
                dist := math.sqrt(dist_sqr)
                force := (min_dist - dist) / min_dist

                sep_dir := diff.xz / dist
                separation.xz += sep_dir * force
                neighbor_count += 1
            }
        }
    }

    if neighbor_count > 0 {
        separation /= f32(neighbor_count)
    }

    return separation
}
