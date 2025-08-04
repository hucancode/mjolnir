package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/navigation/recast"
import "mjolnir/resource"
import "vendor:glfw"
import mu "vendor:microui"

// Navigation mesh visual example - demonstrates rendering the navigation mesh
navmesh_visual_main :: proc() {
    log.info("=== Navigation Mesh Visual Example ===")
    
    // Initialize and run the engine with our custom setup
    mjolnir.init(&engine, 1280, 720, "Navigation Mesh Visualization")
    defer mjolnir.deinit(&engine)
    
    engine.setup_proc = navmesh_setup
    engine.update_proc = navmesh_update
    engine.render2d_proc = navmesh_render2d
    engine.key_press_proc = navmesh_key_pressed
    
    mjolnir.run(&engine, 1280, 720, "Navigation Mesh Visualization")
}

// Global state for navigation example
navmesh_state: struct {
    ground_handle: mjolnir.Handle,
    obstacle_handle: mjolnir.Handle,
    show_original_mesh: bool,
    navmesh_built: bool,
    poly_mesh: ^recast.Poly_Mesh,
    detail_mesh: ^recast.Poly_Mesh_Detail,
} = {
    show_original_mesh = true,
}

navmesh_setup :: proc(engine: ^mjolnir.Engine) {
    using mjolnir, geometry
    log.info("Navigation mesh example setup")
    
    // Create materials
    ground_mat_handle, _, _ := create_material(&engine.warehouse)
    obstacle_mat_handle, _, _ := create_material(&engine.warehouse, emissive_value = 0.2)
    
    // Create meshes
    ground_mesh_handle, _, _ := create_mesh(&engine.gpu_context, &engine.warehouse, make_quad())
    box_mesh_handle, _, _ := create_mesh(&engine.gpu_context, &engine.warehouse, make_cube())
    
    // Create ground plane (20x20)
    ground_handle, ground_node := spawn(&engine.scene, MeshAttachment{
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
    })
    scale(&ground_node.transform, 10)  // Scale to 20x20
    navmesh_state.ground_handle = ground_handle
    
    // Create obstacle box (2x3x2) at center
    obstacle_handle, obstacle_node := spawn(&engine.scene, MeshAttachment{
        handle = box_mesh_handle,
        material = obstacle_mat_handle,
        cast_shadow = true,
    })
    translate(&obstacle_node.transform, 0, 1.5, 0)  // Center at y=1.5
    scale(&obstacle_node.transform, 1)  // Base scale
    obstacle_node.transform.scale = [3]f32{2, 1.5, 2}  // Scale to 4x3x4
    navmesh_state.obstacle_handle = obstacle_handle
    
    // Add some lights
    spawn(&engine.scene, DirectionalLightAttachment{
        color = {0.8, 0.8, 0.8, 1.0},
        cast_shadow = true,
    })
    
    spawn(&engine.scene, PointLightAttachment{
        color = {0.5, 0.5, 0.5, 1.0},
        radius = 20,
        cast_shadow = false,
    })
    
    // Setup camera
    main_camera := get_main_camera(engine)
    if main_camera != nil {
        camera_look_at(main_camera, {15, 10, 15}, {0, 0, 0}, {0, 1, 0})
    }
    
    // Build navigation mesh
    build_navmesh(engine)
}

build_navmesh :: proc(engine: ^mjolnir.Engine) {
    using mjolnir, geometry
    
    // Clean up previous mesh if any
    if navmesh_state.poly_mesh != nil {
        recast.free_poly_mesh(navmesh_state.poly_mesh)
        navmesh_state.poly_mesh = nil
    }
    if navmesh_state.detail_mesh != nil {
        recast.free_poly_mesh_detail(navmesh_state.detail_mesh)
        navmesh_state.detail_mesh = nil
    }
    
    // Simulate extracting geometry from scene
    // In a real implementation, this would iterate through scene nodes and extract mesh data
    vertices_list := make([dynamic]f32)
    indices_list := make([dynamic]i32)
    areas_list := make([dynamic]u8)
    defer delete(vertices_list)
    defer delete(indices_list)
    defer delete(areas_list)
    
    vertex_offset := i32(0)
    
    // Simulate ground plane geometry (quad scaled to 20x20)
    // A quad has 4 vertices: (-1,-1), (1,-1), (1,1), (-1,1) in local space
    // Scaled by 10 to get 20x20 world size
    ground_vertices := [][3]f32{
        {-10, 0, -10},  // Bottom-left
        { 10, 0, -10},  // Bottom-right
        { 10, 0,  10},  // Top-right
        {-10, 0,  10},  // Top-left
    }
    
    // Add ground vertices
    for v in ground_vertices {
        append(&vertices_list, v.x, v.y, v.z)
    }
    
    // Ground indices (2 triangles for the quad)
    ground_indices := []i32{
        0, 1, 2,  // First triangle
        0, 2, 3,  // Second triangle
    }
    
    for idx in ground_indices {
        append(&indices_list, idx + vertex_offset)
    }
    
    // Mark ground as walkable
    append(&areas_list, recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA)
    
    vertex_offset += i32(len(ground_vertices))
    
    // Simulate obstacle box geometry (cube scaled to 4x3x4 at position (0, 1.5, 0))
    // A cube has 8 vertices, we need all faces for proper collision
    // Base cube vertices (-1,-1,-1) to (1,1,1), scaled by (2,1.5,2) and translated
    obstacle_vertices := [][3]f32{
        // Bottom face (y=0)
        {-2, 0, -2}, { 2, 0, -2}, { 2, 0,  2}, {-2, 0,  2},
        // Top face (y=3)
        {-2, 3, -2}, { 2, 3, -2}, { 2, 3,  2}, {-2, 3,  2},
    }
    
    // Add obstacle vertices
    for v in obstacle_vertices {
        append(&vertices_list, v.x, v.y, v.z)
    }
    
    // Obstacle indices (12 triangles for 6 faces of the cube)
    obstacle_indices := []i32{
        // Bottom face
        0, 2, 1,  0, 3, 2,
        // Top face
        4, 5, 6,  4, 6, 7,
        // Front face
        0, 1, 5,  0, 5, 4,
        // Back face
        2, 3, 7,  2, 7, 6,
        // Left face
        0, 4, 7,  0, 7, 3,
        // Right face
        1, 2, 6,  1, 6, 5,
    }
    
    for idx in obstacle_indices {
        append(&indices_list, idx + vertex_offset)
    }
    
    // Mark obstacle as non-walkable
    for i in 0..<12 {
        append(&areas_list, recast.RC_NULL_AREA)
    }
    
    vertices := vertices_list[:]
    indices := indices_list[:]
    areas := areas_list[:]
    
    log.infof("Scene geometry: %d vertices, %d triangles", len(vertices)/3, len(indices)/3)
    log.infof("Areas array length: %d", len(areas))
    
    // Configure Recast
    config := recast.Config{
        cs = 0.3,                        // Cell size
        ch = 0.2,                        // Cell height
        walkable_slope_angle = 45,       // Max slope
        walkable_height = 10,            // Min ceiling height
        walkable_climb = 4,              // Max ledge height
        walkable_radius = 1,             // Agent radius in cells (1 * 0.3 = 0.3 units)
        max_edge_len = 12,               // Max edge length
        max_simplification_error = 1.3,  // Simplification error
        min_region_area = 8,             // Min region area
        merge_region_area = 20,          // Merge region area
        max_verts_per_poly = 6,          // Max verts per polygon
        detail_sample_dist = 6,          // Detail sample distance
        detail_sample_max_error = 1,     // Detail sample error
        border_size = 0,                 // No border padding
    }
    
    // Build navigation mesh
    log.info("Building navigation mesh...")
    pmesh, dmesh, ok := recast.build_navmesh(vertices, indices, areas, config)
    if !ok {
        log.error("Failed to build navigation mesh")
        return
    }
    
    navmesh_state.poly_mesh = pmesh
    navmesh_state.detail_mesh = dmesh
    navmesh_state.navmesh_built = true
    
    log.infof("Navigation mesh built: %d polygons, %d vertices", pmesh.npolys, len(pmesh.verts))
    
    // Create visualization
    success := navmesh_renderer_build_from_recast(&engine.navmesh, &engine.gpu_context, pmesh, dmesh)
    if !success {
        log.error("Failed to build navigation mesh renderer")
        return
    }
    
    // Configure the renderer
    engine.navmesh.enabled = true
    engine.navmesh.debug_mode = false  // Use filled polygons
    engine.navmesh.alpha = 0.6
    engine.navmesh.height_offset = 0.05  // Slightly above ground
    engine.navmesh.color_mode = .Area_Colors  // Color by area type
    engine.navmesh.base_color = {0.0, 0.8, 0.2}  // Green
    
    log.infof("Navigation mesh visualization created with %d triangles", 
              navmesh_renderer_get_triangle_count(&engine.navmesh))
}

navmesh_update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
    using mjolnir, geometry
    
    // Simple camera orbit
    main_camera := get_main_camera(engine)
    if main_camera != nil {
        t := time_since_app_start(engine) * 0.2
        radius: f32 = 20
        height: f32 = 12
        
        camera_x := math.cos(t) * radius
        camera_z := math.sin(t) * radius
        camera_pos := [3]f32{camera_x, height, camera_z}
        
        camera_look_at(main_camera, camera_pos, {0, 0, 0}, {0, 1, 0})
    }
}

navmesh_render2d :: proc(engine: ^mjolnir.Engine, ctx: ^mu.Context) {
    using mjolnir
    
    if mu.window(ctx, "Navigation Mesh", {40, 40, 300, 200}, {.NO_CLOSE}) {
        mu.label(ctx, "Navigation Mesh Visualization")
        
        if navmesh_state.navmesh_built {
            mu.label(ctx, "Status: Built")
            if navmesh_state.poly_mesh != nil {
                mu.label(ctx, fmt.tprintf("Polygons: %d", navmesh_state.poly_mesh.npolys))
                mu.label(ctx, fmt.tprintf("Vertices: %d", len(navmesh_state.poly_mesh.verts)))
            }
            
            // Toggle original mesh visibility
            mu.checkbox(ctx, "Show Original Mesh", &navmesh_state.show_original_mesh)
            // Note: Node visibility control not implemented in current engine version
            
            // Navigation mesh settings
            mu.label(ctx, "NavMesh Settings:")
            
            // Toggle navmesh visibility
            enabled := engine.navmesh.enabled
            if .CHANGE in mu.checkbox(ctx, "Show NavMesh", &enabled) {
                engine.navmesh.enabled = enabled
            }
            
            // Toggle debug mode
            debug_mode := engine.navmesh.debug_mode
            if .CHANGE in mu.checkbox(ctx, "Wireframe Mode", &debug_mode) {
                engine.navmesh.debug_mode = debug_mode
            }
            
            // Alpha slider
            alpha := engine.navmesh.alpha
            mu.slider(ctx, &alpha, 0.0, 1.0)
            engine.navmesh.alpha = alpha
            mu.label(ctx, fmt.tprintf("Alpha: %.2f", alpha))
            
            // Height offset slider
            height := engine.navmesh.height_offset
            mu.slider(ctx, &height, 0.0, 0.5)
            engine.navmesh.height_offset = height
            mu.label(ctx, fmt.tprintf("Height Offset: %.2f", height))
            
            // Color mode selection
            if .SUBMIT in mu.button(ctx, "Next Color Mode") {
                mode := int(engine.navmesh.color_mode)
                mode = (mode + 1) % 4
                engine.navmesh.color_mode = mjolnir.NavMeshColorMode(mode)
            }
            mu.label(ctx, fmt.tprintf("Color Mode: %v", engine.navmesh.color_mode))
            
        } else {
            mu.label(ctx, "Status: Not Built")
            if .SUBMIT in mu.button(ctx, "Build NavMesh") {
                build_navmesh(engine)
            }
        }
    }
}

navmesh_key_pressed :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
    using mjolnir, geometry
    
    if action != glfw.PRESS do return
    
    switch key {
    case glfw.KEY_R:
        // Rebuild navigation mesh
        log.info("Rebuilding navigation mesh...")
        build_navmesh(engine)
        
    case glfw.KEY_V:
        // Toggle navmesh visibility
        engine.navmesh.enabled = !engine.navmesh.enabled
        log.infof("NavMesh visibility: %v", engine.navmesh.enabled)
        
    case glfw.KEY_W:
        // Toggle wireframe mode
        engine.navmesh.debug_mode = !engine.navmesh.debug_mode
        log.infof("NavMesh wireframe: %v", engine.navmesh.debug_mode)
        
    case glfw.KEY_M:
        // Toggle original mesh visibility
        navmesh_state.show_original_mesh = !navmesh_state.show_original_mesh
        // Note: Node visibility control not implemented in current engine version
        log.infof("Original mesh visibility: %v (not implemented)", navmesh_state.show_original_mesh)
        
    case glfw.KEY_C:
        // Cycle color modes
        mode := int(engine.navmesh.color_mode)
        mode = (mode + 1) % 4
        engine.navmesh.color_mode = mjolnir.NavMeshColorMode(mode)
        log.infof("NavMesh color mode: %v", engine.navmesh.color_mode)
    }
}
