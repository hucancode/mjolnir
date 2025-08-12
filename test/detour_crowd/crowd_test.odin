package test_detour_crowd

import "core:testing"
import "core:time"
import "core:math"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

// Mock navigation query for testing
create_mock_nav_query :: proc() -> ^detour.Nav_Mesh_Query {
    // In a real implementation, this would create a proper navigation mesh
    // For testing, we'll create a minimal mock
    nav_query := new(detour.Nav_Mesh_Query)
    nav_mesh := new(detour.Nav_Mesh)
    nav_query.nav_mesh = nav_mesh
    return nav_query
}

cleanup_mock_nav_query :: proc(nav_query: ^detour.Nav_Mesh_Query) {
    if nav_query != nil {
        if nav_query.nav_mesh != nil {
            free(nav_query.nav_mesh)
        }
        free(nav_query)
    }
}

@(test)
test_crowd_creation_and_destruction :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_query := create_mock_nav_query()
    defer cleanup_mock_nav_query(nav_query)

    // Test crowd creation
    crowd_system, status := crowd.crowd_create(10, 2.0, nav_query)
    testing.expect(t, recast.status_succeeded(status), "Failed to create crowd")
    testing.expect(t, crowd_system != nil, "Crowd system is nil")

    if crowd_system != nil {
        testing.expect(t, crowd_system.max_agents == 10, "Max agents not set correctly")
        testing.expect(t, crowd_system.max_agent_radius == 2.0, "Max agent radius not set correctly")
        testing.expect(t, crowd_system.nav_query == nav_query, "Nav query not set correctly")

        // Test crowd destruction
        crowd.crowd_destroy(crowd_system)
    }
}

@(test)
test_agent_params_defaults :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test default agent parameters
    params := crowd.agent_params_create_default()

    testing.expect(t, params.radius > 0, "Default radius should be positive")
    testing.expect(t, params.height > 0, "Default height should be positive")
    testing.expect(t, params.max_speed > 0, "Default max speed should be positive")
    testing.expect(t, params.max_acceleration > 0, "Default max acceleration should be positive")
    testing.expect(t, params.collision_query_range > 0, "Default collision query range should be positive")

    // Test preset parameters
    soldier_params := crowd.agent_params_create_soldier()
    civilian_params := crowd.agent_params_create_civilian()
    vehicle_params := crowd.agent_params_create_vehicle()

    testing.expect(t, soldier_params.radius != civilian_params.radius, "Soldier and civilian should have different radii")
    testing.expect(t, vehicle_params.radius > soldier_params.radius, "Vehicle should be larger than soldier")
    testing.expect(t, vehicle_params.max_speed > civilian_params.max_speed, "Vehicle should be faster than civilian")
}

@(test)
test_obstacle_avoidance_params :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test default obstacle avoidance parameters
    default_params := crowd.obstacle_avoidance_params_create_default()

    testing.expect(t, default_params.vel_bias >= 0 && default_params.vel_bias <= 1, "Velocity bias should be normalized")
    testing.expect(t, default_params.weight_des_vel > 0, "Desired velocity weight should be positive")
    testing.expect(t, default_params.horiz_time > 0, "Horizon time should be positive")
    testing.expect(t, default_params.grid_size > 0, "Grid size should be positive")

    // Test quality presets
    low_quality := crowd.obstacle_avoidance_params_create_low_quality()
    medium_quality := crowd.obstacle_avoidance_params_create_medium_quality()
    high_quality := crowd.obstacle_avoidance_params_create_high_quality()

    testing.expect(t, low_quality.grid_size < medium_quality.grid_size, "Low quality should have smaller grid")
    testing.expect(t, medium_quality.grid_size < high_quality.grid_size, "Medium quality should have smaller grid than high")
    testing.expect(t, low_quality.adaptive_divs <= high_quality.adaptive_divs, "High quality should have more adaptive divisions")
}

@(test)
test_proximity_grid :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    grid := new(crowd.Proximity_Grid)
    defer free(grid)

    // Test grid initialization
    status := crowd.proximity_grid_init(grid, 100, 2.0)
    testing.expect(t, recast.status_succeeded(status), "Failed to initialize proximity grid")
    defer crowd.proximity_grid_destroy(grid)

    testing.expect(t, grid.max_items == 100, "Max items not set correctly")
    testing.expect(t, grid.cell_size == 2.0, "Cell size not set correctly")
    testing.expect(t, grid.inv_cell_size == 0.5, "Inverse cell size not calculated correctly")

    // Test adding items
    status = crowd.proximity_grid_add_item(grid, 1, 0, 0, 2, 2)
    testing.expect(t, recast.status_succeeded(status), "Failed to add item to grid")

    status = crowd.proximity_grid_add_item(grid, 2, 3, 3, 5, 5)
    testing.expect(t, recast.status_succeeded(status), "Failed to add second item to grid")

    // Test querying items
    items := make([]u16, 10)
    defer delete(items)

    count := crowd.proximity_grid_query_items(grid, 1, 1, 3.0, items[:], 10)
    testing.expect(t, count > 0, "Should find items in query")
    testing.expect(t, count <= 10, "Should not exceed max items")

    // Test clearing grid
    crowd.proximity_grid_clear(grid)
    testing.expect(t, crowd.proximity_grid_is_empty(grid), "Grid should be empty after clear")
}

@(test)
test_path_corridor :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    corridor := new(crowd.Path_Corridor)
    defer free(corridor)

    // Test corridor initialization
    status := crowd.path_corridor_init(corridor, 100)
    testing.expect(t, recast.status_succeeded(status), "Failed to initialize path corridor")
    defer crowd.path_corridor_destroy(corridor)

    testing.expect(t, corridor.max_path == 100, "Max path not set correctly")
    testing.expect(t, len(corridor.path) == 0, "Path should be empty initially")

    // Test resetting corridor
    test_ref := recast.Poly_Ref(123)
    test_pos := [3]f32{1, 2, 3}

    status = crowd.path_corridor_reset(corridor, test_ref, test_pos)
    testing.expect(t, recast.status_succeeded(status), "Failed to reset corridor")
    testing.expect(t, len(corridor.path) == 1, "Path should have one polygon after reset")
    testing.expect(t, corridor.path[0] == test_ref, "First polygon should match")
    testing.expect(t, corridor.position == test_pos, "Position should match")

    // Test getting first and last polygon
    first_poly := crowd.path_corridor_get_first_poly(corridor)
    testing.expect(t, first_poly == test_ref, "First polygon should match")

    last_poly := crowd.path_corridor_get_last_poly(corridor)
    testing.expect(t, last_poly == test_ref, "Last polygon should match when path has one element")
}

@(test)
test_local_boundary :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    boundary := new(crowd.Local_Boundary)
    defer free(boundary)

    // Test boundary initialization
    status := crowd.local_boundary_init(boundary, 10)
    testing.expect(t, recast.status_succeeded(status), "Failed to initialize local boundary")
    defer crowd.local_boundary_destroy(boundary)

    testing.expect(t, boundary.max_segs == 10, "Max segments not set correctly")
    testing.expect(t, len(boundary.segments) == 0, "Segments should be empty initially")

    // Test point-to-segment distance calculation
    point := [3]f32{0, 0, 0}
    seg_start := [3]f32{-1, 0, 0}
    seg_end := [3]f32{1, 0, 0}

    dist := crowd.dt_distance_point_to_segment_2d(point, seg_start, seg_end)
    testing.expect(t, math.abs(dist) < 0.01, "Point should be on segment (distance ~0)")

    point_off := [3]f32{0, 0, 1}
    dist_off := crowd.dt_distance_point_to_segment_2d(point_off, seg_start, seg_end)
    testing.expect(t, math.abs(dist_off - 1.0) < 0.01, "Distance should be 1.0")

    // Test closest point on segment
    closest := crowd.dt_closest_point_on_segment_2d(point_off, seg_start, seg_end)
    expected_closest := [3]f32{0, 0, 0}
    testing.expect(t, math.abs(closest[0] - expected_closest[0]) < 0.01, "Closest point X should match")
    testing.expect(t, math.abs(closest[2] - expected_closest[2]) < 0.01, "Closest point Z should match")
}

@(test)
test_obstacle_avoidance_query :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    query := new(crowd.Obstacle_Avoidance_Query)
    defer free(query)

    // Test query initialization
    status := crowd.obstacle_avoidance_query_init(query, 10, 20)
    testing.expect(t, recast.status_succeeded(status), "Failed to initialize obstacle avoidance query")
    defer crowd.obstacle_avoidance_query_destroy(query)

    testing.expect(t, query.max_circles == 10, "Max circles not set correctly")
    testing.expect(t, query.max_segments == 20, "Max segments not set correctly")

    // Test adding circle obstacle
    pos := [3]f32{1, 0, 1}
    vel := [3]f32{0, 0, 1}
    dvel := [3]f32{0, 0, 0.5}

    status = crowd.obstacle_avoidance_query_add_circle(query, pos, vel, dvel, 1.0, {}, {})
    testing.expect(t, recast.status_succeeded(status), "Failed to add circle obstacle")
    testing.expect(t, len(query.circle_obstacles) == 1, "Should have one circle obstacle")

    // Test adding segment obstacle
    seg_p := [3]f32{0, 0, 0}
    seg_q := [3]f32{2, 0, 0}

    status = crowd.obstacle_avoidance_query_add_segment(query, seg_p, seg_q, false)
    testing.expect(t, recast.status_succeeded(status), "Failed to add segment obstacle")
    testing.expect(t, len(query.segment_obstacles) == 1, "Should have one segment obstacle")

    // Test reset
    crowd.obstacle_avoidance_query_reset(query)
    testing.expect(t, len(query.circle_obstacles) == 0, "Circle obstacles should be cleared")
    testing.expect(t, len(query.segment_obstacles) == 0, "Segment obstacles should be cleared")
}

@(test)
test_path_queue :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_query := create_mock_nav_query()
    defer cleanup_mock_nav_query(nav_query)

    queue := new(crowd.Path_Queue)
    defer free(queue)

    // Test queue initialization
    status := crowd.path_queue_init(queue, 100, 1000, nav_query)
    testing.expect(t, recast.status_succeeded(status), "Failed to initialize path queue")
    defer crowd.path_queue_destroy(queue)

    testing.expect(t, queue.max_path_size == 100, "Max path size not set correctly")
    testing.expect(t, queue.max_search_nodes == 1000, "Max search nodes not set correctly")
    testing.expect(t, queue.nav_query == nav_query, "Nav query not set correctly")

    // Test queue state
    testing.expect(t, crowd.path_queue_is_empty(queue), "Queue should be empty initially")
    testing.expect(t, !crowd.path_queue_is_full(queue), "Queue should not be full initially")

    // Test statistics
    queue_size, max_queue_size := crowd.path_queue_get_stats(queue)
    testing.expect(t, queue_size == 0, "Queue size should be 0")
    testing.expect(t, max_queue_size > 0, "Max queue size should be positive")

    pending_count := crowd.path_queue_get_pending_count(queue)
    completed_count := crowd.path_queue_get_completed_count(queue)
    testing.expect(t, pending_count == 0, "Pending count should be 0")
    testing.expect(t, completed_count == 0, "Completed count should be 0")
}

@(test)
test_crowd_agent_management :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_query := create_mock_nav_query()
    defer cleanup_mock_nav_query(nav_query)

    // Create crowd system
    crowd_system, status := crowd.crowd_create(5, 1.0, nav_query)
    testing.expect(t, recast.status_succeeded(status), "Failed to create crowd")
    defer crowd.crowd_destroy(crowd_system)

    if crowd_system == nil do return

    // Test initial state
    testing.expect(t, crowd.crowd_get_agent_count(crowd_system) == 0, "Should have no agents initially")

    // Test agent parameter creation
    params := crowd.agent_params_create_default()
    testing.expect(t, params.radius > 0, "Agent radius should be positive")

    // Test statistics
    stats := crowd.crowd_get_statistics(crowd_system)
    testing.expect(t, stats.active_agents == 0, "Should have 0 active agents")
    testing.expect(t, stats.max_agents == 5, "Max agents should be 5")
}

@(test)
test_agent_utility_functions :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Test agent state queries with nil agent
    pos := crowd.agent_get_position(nil)
    testing.expect(t, pos == [3]f32{}, "Position should be zero for nil agent")

    vel := crowd.agent_get_velocity(nil)
    testing.expect(t, vel == [3]f32{}, "Velocity should be zero for nil agent")

    state := crowd.agent_get_state(nil)
    testing.expect(t, state == .Invalid, "State should be invalid for nil agent")

    active := crowd.agent_is_active(nil)
    testing.expect(t, !active, "Agent should not be active for nil agent")

    corner_count := crowd.agent_get_corner_count(nil)
    testing.expect(t, corner_count == 0, "Corner count should be 0 for nil agent")

    // Test corner retrieval with invalid index
    _, _, _, found := crowd.agent_get_corner(nil, 0)
    testing.expect(t, !found, "Should not find corner for nil agent")

    neighbor_count := crowd.agent_get_neighbor_count(nil)
    testing.expect(t, neighbor_count == 0, "Neighbor count should be 0 for nil agent")

    _, neighbor_found := crowd.agent_get_neighbor(nil, 0)
    testing.expect(t, !neighbor_found, "Should not find neighbor for nil agent")
}

@(test)
test_crowd_utility_functions :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    nav_query := create_mock_nav_query()
    defer cleanup_mock_nav_query(nav_query)

    crowd_system, status := crowd.crowd_create(3, 1.0, nav_query)
    testing.expect(t, recast.status_succeeded(status), "Failed to create crowd")
    defer crowd.crowd_destroy(crowd_system)

    if crowd_system == nil do return

    // Test getting filter
    filter := crowd.crowd_get_filter(crowd_system, 0)
    testing.expect(t, filter != nil, "Should get valid filter")

    editable_filter := crowd.crowd_get_editable_filter(crowd_system, 0)
    testing.expect(t, editable_filter != nil, "Should get valid editable filter")
    testing.expect(t, filter == editable_filter, "Filter and editable filter should be the same")

    // Test invalid filter index
    invalid_filter := crowd.crowd_get_filter(crowd_system, 999)
    testing.expect(t, invalid_filter == nil, "Should return nil for invalid filter index")

    // Test obstacle avoidance parameters
    params := crowd.obstacle_avoidance_params_create_default()
    set_status := crowd.crowd_set_obstacle_avoidance_params(crowd_system, 0, &params)
    testing.expect(t, recast.status_succeeded(set_status), "Failed to set obstacle avoidance params")

    retrieved_params := crowd.crowd_get_obstacle_avoidance_params(crowd_system, 0)
    testing.expect(t, retrieved_params != nil, "Should retrieve obstacle avoidance params")

    // Test invalid parameter index
    invalid_params := crowd.crowd_get_obstacle_avoidance_params(crowd_system, 999)
    testing.expect(t, invalid_params == nil, "Should return nil for invalid params index")
}
