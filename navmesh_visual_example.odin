package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/navigation"
import "mjolnir/navigation/recast"
import "mjolnir/navigation/detour"
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
    show_original_mesh: bool,
    navmesh_built: bool,
    poly_mesh: ^recast.Poly_Mesh,
    detail_mesh: ^recast.Poly_Mesh_Detail,

    // Original OBJ mesh
    obj_mesh_handle: mjolnir.Handle,
    obj_mesh_node: ^mjolnir.Node,
    obj_node_handle: mjolnir.Handle,

    // Pathfinding state
    nav_mesh: ^detour.Nav_Mesh,
    nav_query: ^detour.Nav_Mesh_Query,
    filter: detour.Query_Filter,

    // Path visualization
    start_pos: [3]f32,
    end_pos: [3]f32,
    path_points: [dynamic][3]f32,
    has_path: bool,
    path_status: recast.Status,

    // Visualization handles
    start_sphere_handle: mjolnir.Handle,
    end_sphere_handle: mjolnir.Handle,
    path_waypoint_handles: [dynamic]mjolnir.Handle,
} = {
    show_original_mesh = true,
}

navmesh_setup :: proc(engine: ^mjolnir.Engine) {
    using mjolnir, geometry
    log.info("Navigation mesh example setup")

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

    // Don't generate path automatically - wait for user to press P
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

    // Try to load from OBJ file first
    // Default to smaller test file, or use command line argument if provided
    obj_file := "assets/test_floor_13x13.obj"
    if len(os.args) > 2 {
        obj_file = os.args[2]
    }
    vertices: []f32
    indices: []i32
    areas: []u8
    defer delete(vertices)
    defer delete(indices)
    defer delete(areas)

    load_ok := false

    if os.exists(obj_file) {
        log.infof("Loading navigation mesh from OBJ file: %s", obj_file)
        vertices, indices, areas, load_ok = navigation.load_obj_to_navmesh_input(obj_file, 1.0, recast.RC_WALKABLE_AREA)

        if load_ok {
            log.infof("Successfully loaded OBJ file with %d vertices and %d triangles", len(vertices)/3, len(indices)/3)

            // Create mesh for OBJ visualization
            // TODO: Fix OBJ visualization - temporarily disabled due to crash
            // create_obj_visualization_mesh(engine, obj_file)
        } else {
            log.warn("Failed to load OBJ file, falling back to procedural geometry")
        }
    }

    log.infof("Scene geometry: %d vertices, %d triangles", len(vertices)/3, len(indices)/3)
    log.infof("Areas array length: %d", len(areas))

    // Configure Recast
    config := recast.Config{
        cs = 0.15,                       // Cell size (very fine detail)
        ch = 0.2,                        // Cell height
        walkable_slope_angle = 45,       // Max slope
        walkable_height = 10,            // Min ceiling height
        walkable_climb = 4,              // Max ledge height
        walkable_radius = 3,             // Agent radius in cells (3 * 0.15 = 0.45 units)
        max_edge_len = 2,                // Max edge length (reduced for smaller polygons)
        max_simplification_error = 0.2,  // Simplification error (very low for precision)
        min_region_area = 1,             // Min region area (smallest possible)
        merge_region_area = 20,          // Merge region area
        max_verts_per_poly = 6,          // Max verts per polygon
        detail_sample_dist = 2,          // Detail sample distance (more detail)
        detail_sample_max_error = 0.3,   // Detail sample error (high accuracy)
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
    log.infof("Poly mesh bounds: min=(%.2f, %.2f, %.2f) max=(%.2f, %.2f, %.2f)",
              pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z,
              pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z)

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

    // Create navigation mesh for pathfinding
    nav_mesh, nav_ok := detour.create_navmesh(pmesh, dmesh, f32(config.walkable_height) * config.ch,
                                               f32(config.walkable_radius) * config.cs,
                                               f32(config.walkable_climb) * config.ch)
    if !nav_ok {
        log.error("Failed to create Detour navigation mesh")
        return
    }
    navmesh_state.nav_mesh = nav_mesh

    // Log nav mesh info
    log.infof("Detour nav mesh created successfully")

    // Create navigation query
    nav_query := new(detour.Nav_Mesh_Query)
    query_status := detour.nav_mesh_query_init(nav_query, nav_mesh, 2048)
    if recast.status_failed(query_status) {
        log.error("Failed to create navigation query")
        return
    }
    navmesh_state.nav_query = nav_query

    // Initialize filter
    detour.query_filter_init(&navmesh_state.filter)
}

// Create visualization mesh for the loaded OBJ
create_obj_visualization_mesh :: proc(engine: ^mjolnir.Engine, obj_file: string) {
    using mjolnir, geometry

    log.infof("Creating OBJ visualization from file: %s", obj_file)

    // Load OBJ directly to Geometry format
    geom, ok := geometry.load_obj(obj_file, 1.0)
    if !ok {
        log.error("Failed to load OBJ file as geometry")
        return
    }

    // Create mesh
    navmesh_state.obj_mesh_handle, _, _ = create_mesh(
        &engine.gpu_context,
        &engine.warehouse,
        geom,
    )

    // Create a semi-transparent material
    obj_material_handle, _, _ := create_material(
        &engine.warehouse,
        metallic_value = 0.1,
        roughness_value = 0.8,
        emissive_value = 0.02,  // Very slight emissive
    )

    // Spawn the mesh in the scene
    navmesh_state.obj_node_handle, navmesh_state.obj_mesh_node = spawn(
        &engine.scene,
        MeshAttachment{
            handle = navmesh_state.obj_mesh_handle,
            material = obj_material_handle,
            cast_shadow = false,
        },
    )

    // Initially show the mesh
    navmesh_state.show_original_mesh = true
    navmesh_state.obj_mesh_node.visible = true

    log.infof("Created OBJ visualization mesh with %d vertices", len(geom.vertices))
}

// Generate a random point on the navigation mesh
generate_random_navmesh_point :: proc(engine: ^mjolnir.Engine) -> (point: [3]f32, found: bool) {
    if navmesh_state.nav_query == nil || navmesh_state.nav_mesh == nil {
        return {}, false
    }

    // Random position within the walkable area (avoiding edges and obstacle)
    // Using conservative bounds to ensure we're on the navmesh
    rand_x := rand.float32_range(-5, 5)
    rand_z := rand.float32_range(-5, 5)

    // If we're near the center obstacle, push out
    if abs(rand_x) < 3 && abs(rand_z) < 3 {
        if rand_x > 0 {
            rand_x = rand.float32_range(3, 5)
        } else {
            rand_x = rand.float32_range(-5, -3)
        }
    }

    start_pos := [3]f32{rand_x, 1.0, rand_z}  // Start at reasonable height

    // Find nearest polygon on navmesh
    half_extents := [3]f32{5.0, 10.0, 5.0}  // Larger search box
    status, poly_ref, nearest_pos := detour.find_nearest_poly(navmesh_state.nav_query, start_pos, half_extents, &navmesh_state.filter)

    if recast.status_succeeded(status) && poly_ref != recast.INVALID_POLY_REF {
        return nearest_pos, true
    }

    return {}, false
}

// Find path between two points
find_path :: proc(engine: ^mjolnir.Engine) {
    if navmesh_state.nav_query == nil || navmesh_state.nav_mesh == nil {
        log.error("Navigation system not initialized")
        return
    }

    // Clear previous path
    clear(&navmesh_state.path_points)
    navmesh_state.has_path = false

    // Allocate path buffer
    path_buffer := make([][3]f32, 512)
    defer delete(path_buffer)

    // Find nearest polygons first
    half_extents := [3]f32{2.0, 4.0, 2.0}
    start_status, start_ref, start_nearest := detour.find_nearest_poly(navmesh_state.nav_query,
                                                                        navmesh_state.start_pos,
                                                                        half_extents,
                                                                        &navmesh_state.filter)
    end_status, end_ref, end_nearest := detour.find_nearest_poly(navmesh_state.nav_query,
                                                                  navmesh_state.end_pos,
                                                                  half_extents,
                                                                  &navmesh_state.filter)

    log.infof("Start poly ref: %d, nearest: (%.2f, %.2f, %.2f)", start_ref, start_nearest.x, start_nearest.y, start_nearest.z)
    log.infof("End poly ref: %d, nearest: (%.2f, %.2f, %.2f)", end_ref, end_nearest.x, end_nearest.y, end_nearest.z)

    // Find polygon path first
    poly_path := make([]recast.Poly_Ref, 256)
    defer delete(poly_path)

    poly_status, poly_count := detour.find_path(navmesh_state.nav_query, start_ref, end_ref,
                                                 start_nearest, end_nearest,
                                                 &navmesh_state.filter, poly_path[:], 256)
    log.infof("Polygon path status: %v, count: %d", poly_status, poly_count)

    // Log polygon path
    if recast.status_succeeded(poly_status) && poly_count > 0 {
        log.info("Polygon path:")
        for i in 0..<poly_count {
            log.infof("  Poly %d: ref=%d", i, poly_path[i])
        }
    }

    // Find path points (simplified wrapper)
    path_count, status := detour.find_path_points(navmesh_state.nav_query,
                                                   navmesh_state.start_pos,
                                                   navmesh_state.end_pos,
                                                   &navmesh_state.filter,
                                                   path_buffer)

    navmesh_state.path_status = status

    if recast.status_succeeded(status) && path_count > 0 {
        // Copy path points
        for i in 0..<path_count {
            append(&navmesh_state.path_points, path_buffer[i])
        }
        navmesh_state.has_path = true
        log.infof("Path found with %d points", path_count)

        // Log all path points for analysis
        log.info("Path waypoints:")
        for point, idx in navmesh_state.path_points {
            log.infof("  Waypoint %d: (%.2f, %.2f, %.2f)", idx, point.x, point.y, point.z)
        }

        // Calculate total path length
        total_length: f32 = 0
        for i in 0..<len(navmesh_state.path_points)-1 {
            p0 := navmesh_state.path_points[i]
            p1 := navmesh_state.path_points[i+1]
            segment_length := linalg.distance(p0, p1)
            total_length += segment_length
            log.infof("  Segment %d->%d length: %.2f", i, i+1, segment_length)
        }
        log.infof("Total path length: %.2f", total_length)

        // Calculate straight line distance for comparison
        straight_distance := linalg.distance(navmesh_state.start_pos, navmesh_state.end_pos)
        log.infof("Straight line distance: %.2f (path is %.1f%% longer)",
                  straight_distance, (total_length/straight_distance - 1) * 100)
    } else {
        log.error("Failed to find path")
    }
}

// Generate new random points and find path
generate_new_path :: proc(engine: ^mjolnir.Engine) {
    // HARDCODED TEST CASE: Path should go around obstacle
    // Apply the same coordinate shift we used for the navigation mesh
    navmesh_state.start_pos = {-5, 0, -5}
    navmesh_state.end_pos = {5, 0, 5}

    log.infof("Finding path: start=(%.2f, %.2f, %.2f) end=(%.2f, %.2f, %.2f)",
              navmesh_state.start_pos.x, navmesh_state.start_pos.y, navmesh_state.start_pos.z,
              navmesh_state.end_pos.x, navmesh_state.end_pos.y, navmesh_state.end_pos.z)

    // Find path
    find_path(engine)

    // Update visualization
    update_path_visualization(engine)
}

// Update path visualization
update_path_visualization :: proc(engine: ^mjolnir.Engine) {
    using mjolnir, geometry

    // Update navigation mesh renderer with path data
    if navmesh_state.has_path && len(navmesh_state.path_points) >= 2 {
        // Update path in the navmesh renderer
        navmesh_renderer_update_path(&engine.navmesh, navmesh_state.path_points[:], {1.0, 0.8, 0.0, 1.0}) // Orange/yellow path
    } else {
        // Clear path if no valid path
        navmesh_renderer_clear_path(&engine.navmesh)
    }

    // Remove old visualization
    if navmesh_state.start_sphere_handle.generation != 0 {
        despawn(engine, navmesh_state.start_sphere_handle)
        navmesh_state.start_sphere_handle = {}
    }
    if navmesh_state.end_sphere_handle.generation != 0 {
        despawn(engine, navmesh_state.end_sphere_handle)
        navmesh_state.end_sphere_handle = {}
    }

    // Remove old path waypoints (no longer needed with line rendering)
    for handle in navmesh_state.path_waypoint_handles {
        if handle.generation != 0 {
            despawn(engine, handle)
        }
    }
    clear(&navmesh_state.path_waypoint_handles)

    // Create sphere mesh
    sphere_mesh_handle, _, _ := create_mesh(&engine.gpu_context, &engine.warehouse, make_sphere(8, 8))

    // Create materials
    start_mat_handle, _, _ := create_material(&engine.warehouse, metallic_value = 0.0, roughness_value = 0.3, emissive_value = 0.8)
    end_mat_handle, _, _ := create_material(&engine.warehouse, metallic_value = 0.0, roughness_value = 0.3, emissive_value = 0.8)
    path_mat_handle, _, _ := create_material(&engine.warehouse, metallic_value = 0.2, roughness_value = 0.5, emissive_value = 0.4)

    // Create start sphere (green-ish)
    start_handle, start_node := spawn(&engine.scene, MeshAttachment{
        handle = sphere_mesh_handle,
        material = start_mat_handle,
        cast_shadow = false,
    })
    translate(&start_node.transform, navmesh_state.start_pos.x, navmesh_state.start_pos.y + 0.5, navmesh_state.start_pos.z)
    scale(&start_node.transform, 0.4)
    navmesh_state.start_sphere_handle = start_handle

    // Create end sphere (red-ish)
    end_handle, end_node := spawn(&engine.scene, MeshAttachment{
        handle = sphere_mesh_handle,
        material = end_mat_handle,
        cast_shadow = false,
    })
    translate(&end_node.transform, navmesh_state.end_pos.x, navmesh_state.end_pos.y + 0.5, navmesh_state.end_pos.z)
    scale(&end_node.transform, 0.4)
    navmesh_state.end_sphere_handle = end_handle

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

    if mu.window(ctx, "Navigation Mesh", {40, 40, 350, 350}, {.NO_CLOSE}) {
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

            // Pathfinding section
            mu.label(ctx, "")
            mu.label(ctx, "Pathfinding:")

            if .SUBMIT in mu.button(ctx, "Generate Random Path (P)") {
                generate_new_path(engine)
            }

            if navmesh_state.has_path {
                mu.label(ctx, fmt.tprintf("Path Points: %d", len(navmesh_state.path_points)))
                mu.label(ctx, fmt.tprintf("Start: (%.1f, %.1f, %.1f)",
                                         navmesh_state.start_pos.x,
                                         navmesh_state.start_pos.y,
                                         navmesh_state.start_pos.z))
                mu.label(ctx, fmt.tprintf("End: (%.1f, %.1f, %.1f)",
                                         navmesh_state.end_pos.x,
                                         navmesh_state.end_pos.y,
                                         navmesh_state.end_pos.z))
            } else if navmesh_state.path_status != {} {
                mu.label(ctx, "No path found")
            } else {
                mu.label(ctx, "Press P to generate path")
            }

            // Controls help
            mu.label(ctx, "")
            mu.label(ctx, "Controls:")
            mu.label(ctx, "P/Space - Generate Path")
            mu.label(ctx, "R - Rebuild NavMesh")
            mu.label(ctx, "V - Toggle NavMesh")
            mu.label(ctx, "W - Toggle Wireframe")
            mu.label(ctx, "M - Toggle OBJ Mesh")
            mu.label(ctx, "C - Cycle Colors")

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
        if navmesh_state.obj_mesh_node != nil {
            navmesh_state.show_original_mesh = !navmesh_state.show_original_mesh
            navmesh_state.obj_mesh_node.visible = navmesh_state.show_original_mesh
            log.infof("Original mesh visibility: %v", navmesh_state.show_original_mesh)
        } else {
            log.info("No OBJ mesh loaded to toggle visibility")
        }

    case glfw.KEY_C:
        // Cycle color modes
        mode := int(engine.navmesh.color_mode)
        mode = (mode + 1) % 4
        engine.navmesh.color_mode = mjolnir.NavMeshColorMode(mode)
        log.infof("NavMesh color mode: %v", engine.navmesh.color_mode)

    case glfw.KEY_P:
        // Generate new path
        if navmesh_state.navmesh_built {
            log.info("Generating new random path...")
            generate_new_path(engine)
        } else {
            log.warn("Build navigation mesh first (press R)")
        }

    case glfw.KEY_SPACE:
        // Generate new path (alternative key)
        if navmesh_state.navmesh_built {
            log.info("Generating new random path...")
            generate_new_path(engine)
        } else {
            log.warn("Build navigation mesh first (press R)")
        }
    }
}
