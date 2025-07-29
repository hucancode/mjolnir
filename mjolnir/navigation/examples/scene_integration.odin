package navigation_examples

import "core:log"
import "../.." as mjolnir
import nav_recast "../recast"
import recast "../recast"

// Example: Building navigation mesh from scene geometry
example_build_navmesh_from_scene :: proc(engine: ^mjolnir.Engine) -> (mjolnir.Handle, bool) {
    log.info("Building navigation mesh from scene geometry...")
    
    // Create configuration for navigation mesh building
    config := recast.Enhanced_Config{
        base = {
            cs = 0.3,               // Cell size (smaller = more detailed)
            ch = 0.2,               // Cell height  
            walkable_slope_angle = 45.0,
            walkable_height = 2.0,
            walkable_climb = 0.9,
            walkable_radius = 0.6,
            max_edge_len = 12.0,
            max_simplification_error = 1.3,
            min_region_area = 8,
            merge_region_area = 20,
            max_verts_per_poly = 6,
            detail_sample_dist = 6.0,
            detail_sample_max_error = 1.0,
        },
    }
    
    // Build navigation mesh from all scene geometry
    nav_mesh_handle, success := mjolnir.build_navigation_mesh_from_scene(engine, config)
    if !success {
        log.error("Failed to build navigation mesh from scene")
        return nav_mesh_handle, false
    }
    
    log.info("Successfully built navigation mesh from scene")
    return nav_mesh_handle, true
}

// Example: Building filtered navigation mesh (only specific objects)
example_build_filtered_navmesh :: proc(engine: ^mjolnir.Engine) -> (mjolnir.Handle, bool) {
    log.info("Building filtered navigation mesh...")
    
    // Filter function: only include meshes with "ground" or "floor" in their name
    include_filter := proc(node: ^mjolnir.Node) -> bool {
        if _, is_mesh := node.attachment.(mjolnir.MeshAttachment); !is_mesh {
            return false
        }
        
        // Include nodes with specific names
        return node.name == "ground" || node.name == "floor" || node.name == "terrain"
    }
    
    // Area type mapper: assign different costs to different surfaces  
    area_mapper := proc(node: ^mjolnir.Node) -> u8 {
        switch node.name {
        case "ground", "floor":
            return nav_recast.RC_WALKABLE_AREA
        case "terrain":
            return nav_recast.RC_WALKABLE_AREA + 1  // Higher cost terrain
        case:
            return nav_recast.RC_WALKABLE_AREA
        }
    }
    
    config := recast.Enhanced_Config{
        base = {
            cs = 0.2,  // Higher resolution for filtered mesh
            ch = 0.15,
            walkable_slope_angle = 35.0,
            walkable_height = 2.0,
            walkable_climb = 0.5,
            walkable_radius = 0.4,
            max_edge_len = 8.0,
            max_simplification_error = 1.0,
            min_region_area = 4,
            merge_region_area = 10,
            max_verts_per_poly = 6,
            detail_sample_dist = 4.0,
            detail_sample_max_error = 0.8,
        },
    }
    
    nav_mesh_handle, success := mjolnir.build_navigation_mesh_from_scene_filtered(
        engine, include_filter, area_mapper, config
    )
    if !success {
        log.error("Failed to build filtered navigation mesh")
        return nav_mesh_handle, false
    }
    
    log.info("Successfully built filtered navigation mesh")
    return nav_mesh_handle, true
}

// Example: Setting up navigation context and finding paths
example_navigation_pathfinding :: proc(engine: ^mjolnir.Engine, nav_mesh_handle: mjolnir.Handle) -> bool {
    log.info("Setting up navigation pathfinding...")
    
    // Create navigation context for queries
    context_handle, success := mjolnir.create_navigation_context(engine, nav_mesh_handle)
    if !success {
        log.error("Failed to create navigation context")
        return false
    }
    
    // Set as default context
    engine.warehouse.navigation_system.default_context_handle = context_handle
    
    // Test pathfinding
    start_pos := [3]f32{0, 0, 0}
    end_pos := [3]f32{10, 0, 10}
    
    path, path_found := mjolnir.nav_find_path(engine, context_handle, start_pos, end_pos)
    if path_found {
        log.infof("Found path with %d waypoints:", len(path))
        for waypoint, i in path {
            log.infof("  Waypoint %d: (%.2f, %.2f, %.2f)", i, waypoint.x, waypoint.y, waypoint.z)
        }
    } else {
        log.warn("No path found between start and end positions")
    }
    
    // Test position validity
    test_pos := [3]f32{5, 0, 5}
    is_walkable := mjolnir.nav_is_position_walkable(engine, context_handle, test_pos)
    log.infof("Position (%.2f, %.2f, %.2f) is walkable: %v", test_pos.x, test_pos.y, test_pos.z, is_walkable)
    
    return true
}

// Example: Creating and controlling navigation agents
example_navigation_agents :: proc(engine: ^mjolnir.Engine) -> bool {
    log.info("Creating navigation agents...")
    
    // Spawn navigation agent
    agent_handle, agent_node := mjolnir.spawn_nav_agent_at(
        engine, 
        {2, 0, 2},    // position
        0.5,          // radius
        2.0           // height
    )
    if agent_node == nil {
        log.error("Failed to spawn navigation agent")
        return false
    }
    
    agent_node.name = "patrol_agent"
    log.info("Spawned navigation agent")
    
    // Set agent target
    target_pos := [3]f32{8, 0, 8}
    success := mjolnir.nav_agent_set_target(engine, agent_handle, target_pos)
    if success {
        log.infof("Set agent target to (%.2f, %.2f, %.2f)", target_pos.x, target_pos.y, target_pos.z)
    } else {
        log.error("Failed to set agent target")
    }
    
    return true
}

// Complete example workflow
example_complete_navigation_setup :: proc(engine: ^mjolnir.Engine) -> bool {
    log.info("Starting complete navigation setup example...")
    
    // Step 1: Build navigation mesh from scene
    nav_mesh_handle, mesh_success := example_build_navmesh_from_scene(engine)
    if !mesh_success {
        return false
    }
    
    // Step 2: Set up pathfinding context  
    pathfinding_success := example_navigation_pathfinding(engine, nav_mesh_handle)
    if !pathfinding_success {
        return false
    }
    
    // Step 3: Create navigation agents
    agents_success := example_navigation_agents(engine)
    if !agents_success {
        return false
    }
    
    log.info("Complete navigation setup completed successfully!")
    return true
}

// Example: Advanced area type configuration
example_advanced_area_configuration :: proc(engine: ^mjolnir.Engine) -> bool {
    log.info("Configuring advanced area types...")
    
    // Custom area type mapper for different surface types
    advanced_area_mapper := proc(node: ^mjolnir.Node) -> u8 {
        // Check material or node properties to determine area type
        switch node.name {
        case "grass", "dirt":
            return 1  // Normal walkable
        case "mud", "swamp":
            return 2  // Slow movement
        case "road", "stone":
            return 3  // Fast movement
        case "water":
            return nav_recast.RC_NULL_AREA  // Non-walkable
        case "stairs":
            return 4  // Special traversal
        case:
            return nav_recast.RC_WALKABLE_AREA
        }
    }
    
    // Build navigation mesh with area types
    include_all := proc(node: ^mjolnir.Node) -> bool {
        _, is_mesh := node.attachment.(mjolnir.MeshAttachment)
        return is_mesh
    }
    
    config := recast.Enhanced_Config{
        base = {
            cs = 0.25,
            ch = 0.2,
            walkable_slope_angle = 45.0,
            walkable_height = 2.0,
            walkable_climb = 0.9,
            walkable_radius = 0.6,
            max_edge_len = 12.0,
            max_simplification_error = 1.3,
            min_region_area = 8,
            merge_region_area = 20,
            max_verts_per_poly = 6,
            detail_sample_dist = 6.0,
            detail_sample_max_error = 1.0,
        },
    }
    
    nav_mesh_handle, success := mjolnir.build_navigation_mesh_from_scene_filtered(
        engine, include_all, advanced_area_mapper, config
    )
    if !success {
        log.error("Failed to build navigation mesh with advanced areas")
        return false
    }
    
    // Configure area costs in the navigation mesh
    nav_mesh := mjolnir.resource.get(engine.warehouse.nav_meshes, nav_mesh_handle)
    if nav_mesh != nil {
        nav_mesh.area_costs[1] = 1.0   // Normal speed
        nav_mesh.area_costs[2] = 3.0   // 3x slower in mud  
        nav_mesh.area_costs[3] = 0.5   // 2x faster on roads
        nav_mesh.area_costs[4] = 1.5   // Slightly slower on stairs
    }
    
    log.info("Advanced area configuration completed")
    return true
}