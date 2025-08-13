package test_detour_crowd

import "core:testing"
import "core:time"
import "core:fmt"
import recast "../../mjolnir/navigation/recast"
import detour "../../mjolnir/navigation/detour"
import crowd "../../mjolnir/navigation/detour_crowd"

@(test)
test_basic_crowd_creation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    fmt.println("\n=== Testing Basic Crowd Creation ===")

    // Create simple nav mesh
    nav_mesh := new(detour.Nav_Mesh)
    defer free(nav_mesh)

    params := detour.Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = 10.0,
        tile_height = 10.0,
        max_tiles = 1,
        max_polys = 64,
    }

    status := detour.nav_mesh_init(nav_mesh, &params)
    testing.expect(t, recast.status_succeeded(status), "Nav mesh init should succeed")

    // Create nav query
    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)

    status = detour.nav_mesh_query_init(nav_query, nav_mesh, 256)
    testing.expect(t, recast.status_succeeded(status), "Nav query init should succeed")

    // Create crowd
    crowd_system, crowd_status := crowd.crowd_create(10, 2.0, nav_query)
    testing.expect(t, recast.status_succeeded(crowd_status), "Crowd creation should succeed")
    testing.expect(t, crowd_system != nil, "Crowd system should not be nil")

    if crowd_system != nil {
        // Test basic properties
        testing.expect(t, crowd_system.max_agents == 10, "Max agents should be 10")
        testing.expect(t, crowd_system.max_agent_radius == 2.0, "Max agent radius should be 2.0")
        testing.expect(t, crowd.crowd_get_active_agent_count(crowd_system) == 0, "Should have no active agents initially")

        // Test obstacle avoidance params
        params := crowd.obstacle_avoidance_params_create_default()
        status = crowd.crowd_set_obstacle_avoidance_params(crowd_system, 0, &params)
        testing.expect(t, recast.status_succeeded(status), "Should set obstacle avoidance params")

        retrieved := crowd.crowd_get_obstacle_avoidance_params(crowd_system, 0)
        testing.expect(t, retrieved != nil, "Should retrieve obstacle avoidance params")

        // Test filter access
        filter := crowd.crowd_get_filter(crowd_system, 0)
        testing.expect(t, filter != nil, "Should get filter")

        fmt.println("Basic crowd creation test passed")

        // Clean up
        crowd.crowd_destroy(crowd_system)
    }

    detour.nav_mesh_query_destroy(nav_query)
    detour.nav_mesh_destroy(nav_mesh)
}

@(test)
test_agent_add_remove :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    fmt.println("\n=== Testing Agent Add/Remove ===")

    // Setup
    nav_mesh := new(detour.Nav_Mesh)
    defer free(nav_mesh)

    params := detour.Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = 10.0,
        tile_height = 10.0,
        max_tiles = 1,
        max_polys = 64,
    }

    detour.nav_mesh_init(nav_mesh, &params)

    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)
    detour.nav_mesh_query_init(nav_query, nav_mesh, 256)

    crowd_system, _ := crowd.crowd_create(5, 2.0, nav_query)
    defer crowd.crowd_destroy(crowd_system)

    testing.expect(t, crowd_system != nil, "Failed to create crowd system")

    // Test adding agents
    agent_params := crowd.agent_params_create_default()

    agent1_id, status1 := crowd.crowd_add_agent(crowd_system, {1, 0, 1}, &agent_params)
    fmt.printf("Add agent 1: id=%d, status=%v\n", agent1_id, status1)

    agent2_id, status2 := crowd.crowd_add_agent(crowd_system, {2, 0, 2}, &agent_params)
    fmt.printf("Add agent 2: id=%d, status=%v\n", agent2_id, status2)

    // Test total agent count (should return max_agents like C++)
    testing.expect(t, crowd.crowd_get_agent_count(crowd_system) == 5, "Should have 5 total agent slots")
    // Test active agent count  
    testing.expect(t, crowd.crowd_get_active_agent_count(crowd_system) == 2, "Should have 2 active agents")

    // Test getting agents
    agent1 := crowd.crowd_get_agent(crowd_system, agent1_id)
    testing.expect(t, agent1 != nil, "Should get agent 1")
    if agent1 != nil {
        testing.expect(t, agent1.active, "Agent 1 should be active")
    }

    // Test removing agent
    remove_status := crowd.crowd_remove_agent(crowd_system, agent1_id)
    testing.expect(t, recast.status_succeeded(remove_status), "Should remove agent")
    // Test active agent count after removal
    testing.expect(t, crowd.crowd_get_active_agent_count(crowd_system) == 1, "Should have 1 active agent after removal")
    // Total agent count should remain the same
    testing.expect(t, crowd.crowd_get_agent_count(crowd_system) == 5, "Total agent slots should still be 5")

    // Test getting removed agent
    removed_agent := crowd.crowd_get_agent(crowd_system, agent1_id)
    if removed_agent != nil {
        testing.expect(t, !removed_agent.active, "Removed agent should not be active")
    }

    fmt.println("Agent add/remove test passed")

    detour.nav_mesh_query_destroy(nav_query)
    detour.nav_mesh_destroy(nav_mesh)
}

@(test)
test_missing_functions :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    fmt.println("\n=== Testing Missing Functions ===")

    // Setup
    nav_mesh := new(detour.Nav_Mesh)
    defer free(nav_mesh)

    params := detour.Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = 10.0,
        tile_height = 10.0,
        max_tiles = 1,
        max_polys = 64,
    }

    detour.nav_mesh_init(nav_mesh, &params)

    nav_query := new(detour.Nav_Mesh_Query)
    defer free(nav_query)
    detour.nav_mesh_query_init(nav_query, nav_mesh, 256)

    crowd_system, _ := crowd.crowd_create(5, 2.0, nav_query)
    defer crowd.crowd_destroy(crowd_system)

    testing.expect(t, crowd_system != nil, "Failed to create crowd system")

    // Add an agent
    agent_params := crowd.agent_params_create_default()
    agent_id, _ := crowd.crowd_add_agent(crowd_system, {1, 0, 1}, &agent_params)

    // Test updateAgentParameters
    new_params := agent_params
    new_params.max_speed = 5.0
    update_status := crowd.crowd_update_agent_parameters(crowd_system, agent_id, &new_params)
    testing.expect(t, recast.status_succeeded(update_status), "Should update agent parameters")

    agent := crowd.crowd_get_agent(crowd_system, agent_id)
    if agent != nil {
        testing.expect(t, agent.params.max_speed == 5.0, "Agent max speed should be updated")
    }

    // Test resetMoveTarget
    reset_status := crowd.crowd_reset_move_target(crowd_system, agent_id)
    testing.expect(t, recast.status_succeeded(reset_status), "Should reset move target")

    // Test getActiveAgents
    active_agents := crowd.crowd_get_active_agents(crowd_system)
    testing.expect(t, len(active_agents) == 1, "Should have 1 active agent")

    fmt.println("Missing functions test passed")

    detour.nav_mesh_query_destroy(nav_query)
    detour.nav_mesh_destroy(nav_mesh)
}
