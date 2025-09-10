package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:os"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/gpu"
import "mjolnir/navigation"
import "mjolnir/navigation/recast"
import "mjolnir/navigation/detour"
import "mjolnir/resource"
import "vendor:glfw"
import mu "vendor:microui"

/*
NAVIGATION MESH SERIALIZATION DEMONSTRATION

This example demonstrates the complete offline/runtime workflow with serialization:

1. GEOMETRY INPUT:
   - Load OBJ file (if provided as argument) OR use procedural geometry
   - Convert to navigation input format

2. OFFLINE PHASE (Recast):
   - Build heightfield from geometry
   - Generate navigation mesh polygons
   - Create detail mesh

3. SERIALIZATION:
   - Save navigation mesh to file (.navmesh format)
   - Persistent storage for runtime loading

4. RUNTIME PHASE (Detour):
   - Load navigation mesh from file
   - Create pathfinding query system
   - Perform real-time path queries

5. VISUALIZATION:
   - Render navigation mesh
   - Interactive path planning with mouse
   - Visual feedback for serialization status

USAGE:
    ./navmesh_visual_example [obj_file]
    ./navmesh_visual_example procedural   # Use built-in geometry

CONTROLS:
    S - Save navigation mesh to file
    L - Load navigation mesh from file
    R - Rebuild navigation mesh from geometry
    Left Click - Set start position
    Right Click - Set end position and find path

DEMONSTRATION FLOW:
    1. App starts and builds navmesh from geometry (offline phase)
    2. Press S to save navmesh to file (serialization)
    3. Press L to load navmesh from file (runtime phase)
    4. Use mouse to test pathfinding on loaded mesh
*/

// Navigation mesh visual example - demonstrates rendering the navigation mesh with serialization
// Global engine instance for navmesh demo (avoids stack overflow)
global_navmesh_engine: mjolnir.Engine

navmesh_visual_main :: proc() {
    // Initialize and run the engine with our custom setup
    global_navmesh_engine.setup_proc = navmesh_setup
    global_navmesh_engine.update_proc = navmesh_update
    global_navmesh_engine.render2d_proc = navmesh_render2d
    global_navmesh_engine.key_press_proc = navmesh_key_pressed
    global_navmesh_engine.mouse_press_proc = navmesh_mouse_pressed
    global_navmesh_engine.mouse_move_proc = navmesh_mouse_moved

    mjolnir.run(&global_navmesh_engine, 1280, 720, "Navigation Mesh with Serialization")
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
    path_waypoint_handles: [dynamic]mjolnir.Handle,
    start_marker_handle: mjolnir.Handle,
    end_marker_handle: mjolnir.Handle,

    // Mouse picking state
    picking_mode: PickingMode,
    hover_pos: [3]f32,
    hover_valid: bool,
    last_mouse_pos: [2]f32,
    mouse_move_threshold: f32,

    // Serialization state
    serialized_navmesh_path: string,
    serialization_status: string,

    // Workflow demonstration state
    workflow_phase: WorkflowPhase,
    phase_description: string,

    // Camera control
    camera_auto_rotate: bool,
    camera_distance: f32,
    camera_height: f32,
    camera_angle: f32,
} = {
    show_original_mesh = true,
    camera_auto_rotate = false,
    camera_distance = 40,
    camera_height = 25,
    camera_angle = 0,
    mouse_move_threshold = 5.0,  // Only update hover when mouse moves more than 5 pixels
    serialized_navmesh_path = "saved_navmesh.navmesh",
    serialization_status = "Ready",
    workflow_phase = .Initial,
    phase_description = "Starting up...",
}

PickingMode :: enum {
    None,
    PickingStart,
    PickingEnd,
}

WorkflowPhase :: enum {
    Initial,          // Starting state
    GeometryLoaded,   // Geometry input loaded
    OfflineBuilding,  // Recast processing
    OfflineComplete,  // Navigation mesh built
    Serialized,       // Saved to file
    RuntimeLoaded,    // Loaded from file for runtime
    Ready,           // Ready for pathfinding
}

navmesh_setup :: proc(engine_ptr: ^mjolnir.Engine) {
    using mjolnir, geometry
    log.info("Navigation mesh example setup")

    // Initialize dynamic arrays
    navmesh_state.path_points = make([dynamic][3]f32)
    navmesh_state.path_waypoint_handles = make([dynamic]Handle)

    // Add some lights
    spawn(&engine_ptr.scene, DirectionalLightAttachment{
        color = {0.8, 0.8, 0.8, 1.0},
        cast_shadow = true,
    })

    spawn(&engine_ptr.scene, PointLightAttachment{
        color = {0.5, 0.5, 0.5, 1.0},
        radius = 20,
        cast_shadow = false,
    })

    // Setup camera - adjusted for larger scene
    main_camera := get_main_camera(engine_ptr)
    if main_camera != nil {
        camera_look_at(main_camera, {35, 25, 35}, {0, 0, 0}, {0, 1, 0})
    }

    // Build navigation mesh
    use_procedural := build_navmesh(engine_ptr)

    // Start in picking mode
    navmesh_state.picking_mode = .PickingStart

    // Test pathfinding at startup for both procedural and obj geometry
    if use_procedural || true {
        log.info("=== TESTING PATHFINDING AT STARTUP ===")
        log.info("Testing path from corner to corner that should go around obstacles")
        log.info("Note: Ground is 50x50 (-25 to 25), with 5 obstacles well-spaced")
        navmesh_state.start_pos = {-20, 0, -20}
        navmesh_state.end_pos = {20, 0, 20}
        log.infof("Start: (%.2f, %.2f, %.2f), End: (%.2f, %.2f, %.2f)",
            navmesh_state.start_pos.x, navmesh_state.start_pos.y, navmesh_state.start_pos.z,
            navmesh_state.end_pos.x, navmesh_state.end_pos.y, navmesh_state.end_pos.z)

        // Create visual markers for start and end positions
        update_position_marker(engine_ptr, &navmesh_state.start_marker_handle, navmesh_state.start_pos, {0, 1, 0, 1})
        update_position_marker(engine_ptr, &navmesh_state.end_marker_handle, navmesh_state.end_pos, {1, 0, 0, 1})

        // Find and visualize the path
        find_path(&global_navmesh_engine)
        update_path_visualization(&global_navmesh_engine)

        log.info("=== END OF STARTUP PATHFINDING TEST ===")
    }
}

build_navmesh :: proc(engine_ptr: ^mjolnir.Engine) -> (use_procedural: bool) {
    using mjolnir, geometry

    if os.exists(navmesh_state.serialized_navmesh_path) {
        log.info("Loading saved navmesh for runtime use")
        try_load_saved_navmesh(engine_ptr)

        if navmesh_state.nav_mesh != nil {
            obj_file := ""
            if len(os.args) > 2 {
                obj_file = os.args[2]
            }
            use_procedural = obj_file == "" || obj_file == "procedural"

            if !use_procedural && os.exists(obj_file) {
                create_obj_visualization_mesh(engine_ptr, obj_file)
            }

            return use_procedural
        } else {
            log.warn("Failed to load saved navmesh, building from scratch")
        }
    }

    // Clean up previous mesh if any
    if navmesh_state.poly_mesh != nil {
        recast.free_poly_mesh(navmesh_state.poly_mesh)
        navmesh_state.poly_mesh = nil
    }
    if navmesh_state.detail_mesh != nil {
        recast.free_poly_mesh_detail(navmesh_state.detail_mesh)
        navmesh_state.detail_mesh = nil
    }

    obj_file := ""
    if len(os.args) > 2 {
        obj_file = os.args[2]
    }
    vertices: [][3]f32
    indices: []i32
    areas: []u8
    defer delete(vertices)
    defer delete(indices)
    defer delete(areas)

    load_ok := false

    use_procedural = obj_file == "" || obj_file == "procedural"

    if !use_procedural && os.exists(obj_file) {
        vertices, indices, areas, load_ok = navigation.load_obj_to_navmesh_input(obj_file, 1.0, 45.0)

        if load_ok {
            create_obj_visualization_mesh(engine_ptr, obj_file)
        } else {
            log.warn("Failed to load OBJ file, using procedural geometry")
        }
    }

    if !load_ok {

        // Create a larger test scene with ground and multiple well-spaced obstacles
        // Ground quad (50x50 units) - much larger for better navigation
        ground_verts := [][3]f32{
            {-25, 0, -25},  // Bottom-left
            { 25, 0, -25},  // Bottom-right
            { 25, 0,  25},  // Top-right
            {-25, 0,  25},  // Top-left
        }

        // Create multiple smaller obstacles well-spaced and away from edges
        // Smaller obstacles for better connectivity
        // Obstacle 1: Small box at (-10, 0, -10) - reduced from 4x4 to 2x2
        obstacle1_verts := [][3]f32{
            // Bottom face (y=0)
            {-11, 0, -11}, {-9, 0, -11}, {-9, 0, -9}, {-11, 0, -9},
            // Top face (y=3)
            {-11, 3, -11}, {-9, 3, -11}, {-9, 3, -9}, {-11, 3, -9},
        }

        // Obstacle 2: Small box at (10, 0, -10) - reduced from 4x4 to 2x2
        obstacle2_verts := [][3]f32{
            // Bottom face (y=0)
            {9, 0, -11}, {11, 0, -11}, {11, 0, -9}, {9, 0, -9},
            // Top face (y=3)
            {9, 3, -11}, {11, 3, -11}, {11, 3, -9}, {9, 3, -9},
        }

        // Obstacle 3: Small box at (-10, 0, 10) - reduced from 4x4 to 2x2
        obstacle3_verts := [][3]f32{
            // Bottom face (y=0)
            {-11, 0, 9}, {-9, 0, 9}, {-9, 0, 11}, {-11, 0, 11},
            // Top face (y=3)
            {-11, 3, 9}, {-9, 3, 9}, {-9, 3, 11}, {-11, 3, 11},
        }

        // Obstacle 4: Small box at (10, 0, 10) - reduced from 4x4 to 2x2
        obstacle4_verts := [][3]f32{
            // Bottom face (y=0)
            {9, 0, 9}, {11, 0, 9}, {11, 0, 11}, {9, 0, 11},
            // Top face (y=3)
            {9, 3, 9}, {11, 3, 9}, {11, 3, 11}, {9, 3, 11},
        }

        // Obstacle 5: Central obstacle at (0, 0, 0) - reduced from 6x6 to 4x4
        obstacle5_verts := [][3]f32{
            // Bottom face (y=0)
            {-2, 0, -2}, {2, 0, -2}, {2, 0, 2}, {-2, 0, 2},
            // Top face (y=4)
            {-2, 4, -2}, {2, 4, -2}, {2, 4, 2}, {-2, 4, 2},
        }

        log.info("Created larger ground (50x50) with 5 well-spaced obstacles")
        log.info("Obstacles at: (-10,-10), (10,-10), (-10,10), (10,10), and center")

        // Combine vertices
        total_verts := len(ground_verts) + len(obstacle1_verts) + len(obstacle2_verts) +
                      len(obstacle3_verts) + len(obstacle4_verts) + len(obstacle5_verts)
        vertices = make([][3]f32, total_verts)
        offset := 0
        copy(vertices[offset:], ground_verts[:])
        offset += len(ground_verts)
        copy(vertices[offset:], obstacle1_verts[:])
        offset += len(obstacle1_verts)
        copy(vertices[offset:], obstacle2_verts[:])
        offset += len(obstacle2_verts)
        copy(vertices[offset:], obstacle3_verts[:])
        offset += len(obstacle3_verts)
        copy(vertices[offset:], obstacle4_verts[:])
        offset += len(obstacle4_verts)
        copy(vertices[offset:], obstacle5_verts[:])

        // Create indices
        // Ground indices (2 triangles) - CLOCKWISE winding for upward normal
        ground_indices := []i32{
            0, 2, 1,  // First triangle - CW when viewed from above
            0, 3, 2,  // Second triangle - CW when viewed from above
        }

        // Helper to create obstacle indices
        create_box_indices :: proc(base: i32, allocator := context.allocator) -> []i32 {
            indices := make([]i32, 36, allocator)  // 12 triangles * 3 vertices
            // Bottom face
            indices[0] = base + 0; indices[1] = base + 2; indices[2] = base + 1;
            indices[3] = base + 0; indices[4] = base + 3; indices[5] = base + 2;
            // Top face
            indices[6] = base + 4; indices[7] = base + 5; indices[8] = base + 6;
            indices[9] = base + 4; indices[10] = base + 6; indices[11] = base + 7;
            // Front face
            indices[12] = base + 0; indices[13] = base + 1; indices[14] = base + 5;
            indices[15] = base + 0; indices[16] = base + 5; indices[17] = base + 4;
            // Back face
            indices[18] = base + 2; indices[19] = base + 3; indices[20] = base + 7;
            indices[21] = base + 2; indices[22] = base + 7; indices[23] = base + 6;
            // Left face
            indices[24] = base + 0; indices[25] = base + 4; indices[26] = base + 7;
            indices[27] = base + 0; indices[28] = base + 7; indices[29] = base + 3;
            // Right face
            indices[30] = base + 1; indices[31] = base + 2; indices[32] = base + 6;
            indices[33] = base + 1; indices[34] = base + 6; indices[35] = base + 5;
            return indices
        }

        // Create indices for all obstacles
        obstacle1_base := i32(len(ground_verts))
        obstacle1_indices := create_box_indices(obstacle1_base, context.temp_allocator)

        obstacle2_base := obstacle1_base + i32(len(obstacle1_verts))
        obstacle2_indices := create_box_indices(obstacle2_base, context.temp_allocator)

        obstacle3_base := obstacle2_base + i32(len(obstacle2_verts))
        obstacle3_indices := create_box_indices(obstacle3_base, context.temp_allocator)

        obstacle4_base := obstacle3_base + i32(len(obstacle3_verts))
        obstacle4_indices := create_box_indices(obstacle4_base, context.temp_allocator)

        obstacle5_base := obstacle4_base + i32(len(obstacle4_verts))
        obstacle5_indices := create_box_indices(obstacle5_base, context.temp_allocator)

        // Combine indices
        total_indices := len(ground_indices) + len(obstacle1_indices) + len(obstacle2_indices) +
                        len(obstacle3_indices) + len(obstacle4_indices) + len(obstacle5_indices)
        indices = make([]i32, total_indices)
        offset = 0
        copy(indices[offset:], ground_indices[:])
        offset += len(ground_indices)
        copy(indices[offset:], obstacle1_indices[:])
        offset += len(obstacle1_indices)
        copy(indices[offset:], obstacle2_indices[:])
        offset += len(obstacle2_indices)
        copy(indices[offset:], obstacle3_indices[:])
        offset += len(obstacle3_indices)
        copy(indices[offset:], obstacle4_indices[:])
        offset += len(obstacle4_indices)
        copy(indices[offset:], obstacle5_indices[:])

        // Create areas
        num_ground_tris := len(ground_indices) / 3
        num_obstacle_tris := (len(obstacle1_indices) + len(obstacle2_indices) +
                             len(obstacle3_indices) + len(obstacle4_indices) +
                             len(obstacle5_indices)) / 3
        total_tris := num_ground_tris + num_obstacle_tris
        areas = make([]u8, total_tris)
        // Ground is walkable
        for i in 0..<num_ground_tris {
            areas[i] = recast.RC_WALKABLE_AREA
        }
        // All obstacles are not walkable
        for i in num_ground_tris..<total_tris {
            areas[i] = recast.RC_NULL_AREA
        }

        log.infof("Scene geometry: %d vertices, %d triangles", len(vertices), len(indices)/3)
        log.infof("Areas array length: %d", len(areas))
        log.infof("Walkable areas: %d, Non-walkable areas: %d", num_ground_tris, num_obstacle_tris)
    } else {
        log.infof("Scene geometry: %d vertices, %d triangles", len(vertices), len(indices)/3)
        log.infof("Areas array length: %d", len(areas))
    }

    // Configure Recast - Use EXACT RecastDemo default values for consistency
    config := recast.Config{
        cs = 0.3,                                        // Cell size (RecastDemo default)
        ch = 0.2,                                        // Cell height (RecastDemo default)
        walkable_slope_angle = 45,                      // Max slope (RecastDemo default)
        walkable_height = i32(math.ceil_f32(2.0 / 0.2)),    // Agent height = 2.0m -> 10 cells
        walkable_climb = i32(math.floor_f32(0.9 / 0.2)),    // Agent max climb = 0.9m -> 4 cells
        walkable_radius = i32(math.ceil_f32(0.6 / 0.3)),    // Agent radius = 0.6m / cs=0.3 -> 2 cells (RecastDemo default)
        max_edge_len = i32(12.0 / 0.3),                 // Max edge length = 12m -> 40 cells
        max_simplification_error = 1.3,                 // RecastDemo default
        min_region_area = 8 * 8,                        // RecastDemo default (m_regionMinSize=8)
        merge_region_area = 20 * 20,                    // RecastDemo default (m_regionMergeSize=20)
        max_verts_per_poly = 6,                         // RecastDemo default
        detail_sample_dist = 6.0 * 0.3,                 // RecastDemo default (m_detailSampleDist=6 * cs)
        detail_sample_max_error = 1.0 * 0.2,            // RecastDemo default (m_detailSampleMaxError=1 * ch)
        border_size = 0,                                 // No border padding
    }

    // Build navigation mesh
    log.info("=== OFFLINE PHASE: Building Navigation Mesh with Recast ===")
    log.infof("Config: cs=%.2f, ch=%.2f, walkable_radius=%d, min_region=%d, merge_region=%d",
              config.cs, config.ch, config.walkable_radius, config.min_region_area, config.merge_region_area)
    pmesh, dmesh, ok := recast.build_navmesh(vertices, indices, areas, config)
    if !ok {
        log.error("Failed to build navigation mesh")
        return use_procedural
    }

    navmesh_state.poly_mesh = pmesh
    navmesh_state.detail_mesh = dmesh
    navmesh_state.navmesh_built = true

    log.infof("Recast mesh built: %d polygons, %d vertices", pmesh.npolys, len(pmesh.verts))
    log.infof("Poly mesh bounds: min=(%.2f, %.2f, %.2f) max=(%.2f, %.2f, %.2f)",
              pmesh.bmin.x, pmesh.bmin.y, pmesh.bmin.z,
              pmesh.bmax.x, pmesh.bmax.y, pmesh.bmax.z)
    log.info("✓ Offline mesh generation complete")

    // Check for region connectivity
    if pmesh.npolys > 0 {
        log.info("Checking polygon regions...")
        regions := make(map[u16]int, 0, context.temp_allocator)
        for i in 0..<pmesh.npolys {
            region_id := pmesh.regs[i]
            regions[region_id] = regions[region_id] + 1
        }
        log.infof("Found %d distinct regions in navigation mesh:", len(regions))
        for region_id, count in regions {
            log.infof("  Region %d: %d polygons", region_id, count)
        }
        if len(regions) > 1 {
            log.warn("Multiple disconnected regions detected! This will cause pathfinding failures between regions.")
        }
    }

    // Create visualization
    success := navmesh_build_from_recast(&engine_ptr.navmesh, &engine_ptr.gpu_context, pmesh, dmesh)
    if !success {
        log.error("Failed to build navigation mesh renderer")
        return use_procedural
    }

    // Configure the renderer
    engine_ptr.navmesh.enabled = true
    engine_ptr.navmesh.debug_mode = false  // Use filled polygons
    engine_ptr.navmesh.alpha = 0.6
    engine_ptr.navmesh.height_offset = 0.05  // Slightly above ground
    engine_ptr.navmesh.color_mode = .Random_Colors  // Random color per polygon
    engine_ptr.navmesh.base_color = {0.0, 0.8, 0.2}  // Green (not used in random mode)

    log.infof("Navigation mesh visualization created with %d triangles",
              navmesh_get_triangle_count(&engine_ptr.navmesh))

    log.info("=== RUNTIME PHASE: Creating Detour Navigation Mesh ===")

    // Create navigation mesh for pathfinding
    nav_mesh, nav_ok := detour.create_navmesh(pmesh, dmesh, f32(config.walkable_height) * config.ch,
                                               f32(config.walkable_radius) * config.cs,
                                               f32(config.walkable_climb) * config.ch)
    if !nav_ok {
        log.error("Failed to create Detour navigation mesh")
        return use_procedural
    }
    navmesh_state.nav_mesh = nav_mesh

    // Log nav mesh info
    log.infof("✓ Detour nav mesh created successfully")

    // Analyze connectivity from Detour perspective
    analyze_detour_connectivity(nav_mesh)
    analyze_detailed_connections(nav_mesh)

    // Create navigation query
    nav_query := new(detour.Nav_Mesh_Query)
    query_status := detour.nav_mesh_query_init(nav_query, nav_mesh, 2048)
    if recast.status_failed(query_status) {
        log.error("Failed to create navigation query")
        return use_procedural
    }
    navmesh_state.nav_query = nav_query

    // Initialize filter
    detour.query_filter_init(&navmesh_state.filter)

    log.info("✓ Runtime navigation system ready")
    log.info("=== NAVIGATION MESH SETUP COMPLETE ===")
    log.info("💾 Press S to save navigation mesh to file")
    log.info("📁 Press L to load navigation mesh from file")

    // Start in picking mode
    navmesh_state.picking_mode = .PickingStart

    // Update serialization status
    navmesh_state.serialization_status = "Ready - can save navmesh"

    return use_procedural
}

// Create visualization mesh for the loaded OBJ
create_obj_visualization_mesh :: proc(engine_ptr: ^mjolnir.Engine, obj_file: string) {
    using mjolnir, geometry

    log.infof("Creating OBJ visualization from file: %s", obj_file)

    // Load OBJ directly to Geometry format
    geom, ok := geometry.load_obj(obj_file, 1.0)
    if !ok {
        log.error("Failed to load OBJ file as geometry")
        return
    }
    // NOTE: Don't delete geometry here - create_mesh takes ownership of the data
    // The mesh will manage the geometry lifetime

    // Create mesh
    navmesh_state.obj_mesh_handle, _, _ = create_mesh(
        &engine_ptr.gpu_context,
        &engine_ptr.warehouse,
        geom,
    )

    // Create a semi-transparent material
    obj_material_handle, _, _ := create_material(
        &engine_ptr.warehouse,
        metallic_value = 0.1,
        roughness_value = 0.8,
        emissive_value = 0.02,  // Very slight emissive
    )

    // Spawn the mesh in the scene
    navmesh_state.obj_node_handle, navmesh_state.obj_mesh_node = spawn(
        &engine_ptr.scene,
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
generate_random_navmesh_point :: proc(engine_ptr: ^mjolnir.Engine) -> (point: [3]f32, found: bool) {
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
find_path :: proc(engine_ptr: ^mjolnir.Engine) {
    if navmesh_state.nav_query == nil || navmesh_state.nav_mesh == nil {
        log.error("Navigation system not initialized")
        return
    }

    // Clear previous path
    clear(&navmesh_state.path_points)
    navmesh_state.has_path = false
    log.infof("Cleared previous path. path_points capacity: %d", cap(navmesh_state.path_points))

    // Allocate path buffer
    path_buffer := make([][3]f32, 512, context.temp_allocator)

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
    poly_path := make([]recast.Poly_Ref, 256, context.temp_allocator)

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

        // Check if path actually reaches the destination
        if poly_path[poly_count-1] != end_ref {
            log.errorf("PARTIAL PATH: Path doesn't reach destination! Last poly in path: %d, requested end: %d",
                      poly_path[poly_count-1], end_ref)
            log.errorf("This indicates the navigation mesh has disconnected regions - start and end are not connected!")
            // For now, still try to process the partial path
            // Adjust end_nearest to be in the last polygon of the partial path
            last_tile, last_poly, _ := detour.get_tile_and_poly_by_ref(navmesh_state.nav_mesh, poly_path[poly_count-1])
            if last_tile != nil && last_poly != nil {
                end_nearest = detour.calc_poly_center(last_tile, last_poly)
                log.infof("Adjusted end position to last reachable polygon center: %v", end_nearest)
            }
        }
    } else {
        log.errorf("Failed to find polygon path! Status: %v", poly_status)
        return
    }

    // Find path points (simplified wrapper)
    // Use the nearest positions that were actually found on the navmesh
    log.infof("About to call find_path_points with poly_count=%d", poly_count)
    path_count, status := detour.find_path_points(navmesh_state.nav_query,
                                                   start_nearest,
                                                   end_nearest,
                                                   &navmesh_state.filter,
                                                   path_buffer)
    log.infof("find_path_points returned: path_count=%d, status=%v", path_count, status)

    // Also get the polygon centroids for comparison - add safety checks
    log.info("Polygon path centroids (without funnel simplification):")
    for i in 0..<poly_count {
        if i >= i32(len(poly_path)) {
            log.errorf("ERROR: poly_count %d exceeds poly_path length %d", poly_count, len(poly_path))
            break
        }
        poly_ref := poly_path[i]
        if poly_ref == 0 {
            log.errorf("ERROR: Invalid poly ref 0 at index %d", i)
            continue
        }

        tile, poly, status := detour.get_tile_and_poly_by_ref(navmesh_state.nav_mesh, poly_ref)
        if !recast.status_succeeded(status) {
            log.errorf("ERROR: get_tile_and_poly_by_ref failed for ref %d: %v", poly_ref, status)
            continue
        }
        if tile != nil && poly != nil {
            center := detour.calc_poly_center(tile, poly)
            log.infof("  Poly %d center: (%.2f, %.2f, %.2f)", i, center.x, center.y, center.z)
        } else {
            log.errorf("ERROR: get_tile_and_poly_by_ref returned nil tile or poly for ref %d", poly_ref)
        }
    }

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
            // Check if this waypoint is inside any obstacle bounds
            // We have 5 obstacles now (reduced sizes):
            // Obstacle 1: (-11,-11) to (-9,-9)
            // Obstacle 2: (9,-11) to (11,-9)
            // Obstacle 3: (-11,9) to (-9,11)
            // Obstacle 4: (9,9) to (11,11)
            // Obstacle 5 (center): (-2,-2) to (2,2)

            inside_obstacle := false
            obstacle_name := ""

            if point.x >= -11 && point.x <= -9 && point.z >= -11 && point.z <= -9 && point.y <= 3 {
                inside_obstacle = true
                obstacle_name = "Obstacle 1 (bottom-left)"
            } else if point.x >= 9 && point.x <= 11 && point.z >= -11 && point.z <= -9 && point.y <= 3 {
                inside_obstacle = true
                obstacle_name = "Obstacle 2 (bottom-right)"
            } else if point.x >= -11 && point.x <= -9 && point.z >= 9 && point.z <= 11 && point.y <= 3 {
                inside_obstacle = true
                obstacle_name = "Obstacle 3 (top-left)"
            } else if point.x >= 9 && point.x <= 11 && point.z >= 9 && point.z <= 11 && point.y <= 3 {
                inside_obstacle = true
                obstacle_name = "Obstacle 4 (top-right)"
            } else if point.x >= -2 && point.x <= 2 && point.z >= -2 && point.z <= 2 && point.y <= 4 {
                inside_obstacle = true
                obstacle_name = "Obstacle 5 (center)"
            }

            if inside_obstacle {
                log.warnf("    WARNING: Waypoint %d is INSIDE %s!", idx, obstacle_name)
                log.warnf("    Point: (%.2f, %.2f, %.2f)", point.x, point.y, point.z)
            }
        }

        // Calculate total path length
        total_length: f32 = 0
        for i in 0..<len(navmesh_state.path_points)-1 {
            p0 := navmesh_state.path_points[i]
            p1 := navmesh_state.path_points[i+1]
            segment_length := linalg.distance(p0, p1)
            total_length += segment_length
            log.infof("  Segment %d->%d length: %.2f", i, i+1, segment_length)

            // Check if segment crosses any obstacle in X-Z plane
            // Check center obstacle (-3,-3) to (3,3)
            if ((p0.x < -3 && p1.x > 3) || (p0.x > 3 && p1.x < -3)) &&
               ((p0.z >= -3 && p0.z <= 3) || (p1.z >= -3 && p1.z <= 3)) {
                log.warnf("    WARNING: Segment crosses center obstacle in X direction!")
            }
            if ((p0.z < -3 && p1.z > 3) || (p0.z > 3 && p1.z < -3)) &&
               ((p0.x >= -3 && p0.x <= 3) || (p1.x >= -3 && p1.x <= 3)) {
                log.warnf("    WARNING: Segment crosses center obstacle in Z direction!")
            }
        }
        log.infof("Total path length: %.2f", total_length)

        // Calculate straight line distance for comparison
        straight_distance := linalg.distance(navmesh_state.start_pos, navmesh_state.end_pos)
        log.infof("Straight line distance: %.2f (path is %.1f%% longer)",
                  straight_distance, (total_length/straight_distance - 1) * 100)
    } else {
        log.errorf("Failed to find path. Status: %v, Path count: %d", status, path_count)
        log.errorf("Start pos: (%.2f, %.2f, %.2f), End pos: (%.2f, %.2f, %.2f)",
            navmesh_state.start_pos.x, navmesh_state.start_pos.y, navmesh_state.start_pos.z,
            navmesh_state.end_pos.x, navmesh_state.end_pos.y, navmesh_state.end_pos.z)
        log.errorf("Start ref: %d, End ref: %d", start_ref, end_ref)
        log.errorf("Start nearest: (%.2f, %.2f, %.2f), End nearest: (%.2f, %.2f, %.2f)",
            start_nearest.x, start_nearest.y, start_nearest.z,
            end_nearest.x, end_nearest.y, end_nearest.z)
    }
}

// Generate new random points and find path
generate_new_path :: proc(engine_ptr: ^mjolnir.Engine) {
    // HARDCODED TEST CASE: Path should go around obstacle
    // Apply the same coordinate shift we used for the navigation mesh
    navmesh_state.start_pos = {-5, 0, -5}
    navmesh_state.end_pos = {5, 0, 5}

    log.infof("Finding path: start=(%.2f, %.2f, %.2f) end=(%.2f, %.2f, %.2f)",
              navmesh_state.start_pos.x, navmesh_state.start_pos.y, navmesh_state.start_pos.z,
              navmesh_state.end_pos.x, navmesh_state.end_pos.y, navmesh_state.end_pos.z)

    // Find path
    find_path(&global_navmesh_engine)

    // Update visualization
    update_path_visualization(&global_navmesh_engine)
}

// Update path visualization
update_path_visualization :: proc(engine_ptr: ^mjolnir.Engine) {
    using mjolnir, geometry

    // Update navigation mesh renderer with path data
    if navmesh_state.has_path && len(navmesh_state.path_points) >= 2 {
        // Update path in the navmesh renderer
        log.infof("Updating path renderer with %d points", len(navmesh_state.path_points))
        navmesh_update_path(&engine_ptr.navmesh, navmesh_state.path_points[:], {1.0, 0.8, 0.0, 1.0}) // Orange/yellow path
    } else if navmesh_state.has_path && len(navmesh_state.path_points) == 1 {
        log.info("Path has only 1 point - need at least 2 points to draw a line")
        navmesh_clear_path(&engine_ptr.navmesh)
    } else {
        // Clear path if no valid path
        navmesh_clear_path(&engine_ptr.navmesh)
    }

    // Remove old path waypoints (no longer needed with line rendering)
    for handle in navmesh_state.path_waypoint_handles {
        if handle.generation != 0 {
            despawn(engine_ptr, handle)
        }
    }
    clear(&navmesh_state.path_waypoint_handles)
}

// Create or update visual marker for start/end position
update_position_marker :: proc(engine_ptr: ^mjolnir.Engine, handle: ^mjolnir.Handle, pos: [3]f32, color: [4]f32) {
    using mjolnir, geometry

    // Remove old marker if exists
    if handle.generation != 0 {
        despawn(engine_ptr, handle^)
    }

    // Create new marker
    marker_geom := make_sphere(12, 6, 0.3, color)  // Small sphere with color
    // NOTE: Don't delete geometry here - create_mesh takes ownership

    marker_mesh_handle, _, _ := create_mesh(
        &engine_ptr.gpu_context,
        &engine_ptr.warehouse,
        marker_geom,
    )

    // Create colored material for the marker
    marker_material_handle, _, _ := create_material(
        &engine_ptr.warehouse,
        metallic_value = 0.2,
        roughness_value = 0.8,
        emissive_value = 0.5,  // Make it glow a bit
    )

    // Spawn the marker
    node: ^Node
    handle^, node = spawn(
        &engine_ptr.scene,
        MeshAttachment{
            handle = marker_mesh_handle,
            material = marker_material_handle,
            cast_shadow = false,
        },
    )

    // Position the marker slightly above the ground
    if node != nil {
        node.transform.position = pos + {0, 0.2, 0}  // Slightly above ground
    }
}

// Convert screen coordinates to world ray
screen_to_world_ray :: proc(engine_ptr: ^mjolnir.Engine, screen_x, screen_y: f32) -> (ray_origin: [3]f32, ray_dir: [3]f32) {
    using mjolnir, geometry

    main_camera := get_main_camera(engine_ptr)
    if main_camera == nil {
        return {}, {}
    }

    // Get window dimensions
    width, height := glfw.GetWindowSize(engine_ptr.window)

    // Normalize screen coordinates to [-1, 1]
    ndc_x := (2.0 * screen_x / f32(width)) - 1.0
    ndc_y := 1.0 - (2.0 * screen_y / f32(height))  // Flip Y

    // Get camera matrices
    view, proj := camera_calculate_matrices(main_camera^)

    // Compute inverse matrices
    inv_view := linalg.matrix4x4_inverse(view)
    inv_proj := linalg.matrix4x4_inverse(proj)

    // Create ray in clip space
    ray_clip := [4]f32{ndc_x, ndc_y, -1.0, 1.0}

    // Transform to eye space
    ray_eye := inv_proj * ray_clip
    ray_eye = [4]f32{ray_eye.x, ray_eye.y, -1.0, 0.0}  // Point at infinity

    // Transform to world space
    ray_world_4 := inv_view * ray_eye
    ray_world := [3]f32{ray_world_4.x, ray_world_4.y, ray_world_4.z}
    ray_dir = linalg.normalize(ray_world)

    // Ray origin is camera position
    ray_origin = main_camera.position

    return ray_origin, ray_dir
}

// Find intersection of ray with navmesh
ray_navmesh_intersection :: proc(engine_ptr: ^mjolnir.Engine, ray_origin, ray_dir: [3]f32) -> (hit_pos: [3]f32, hit: bool) {
    if navmesh_state.nav_query == nil || navmesh_state.nav_mesh == nil {
        return {}, false
    }

    // Cast ray far enough to hit any reasonable navmesh
    ray_end := ray_origin + ray_dir * 1000.0

    // First, find the nearest polygon to the ray origin to start the raycast
    search_extents := [3]f32{50.0, 50.0, 50.0}  // Large search area
    status, start_ref, nearest_start := detour.find_nearest_poly(navmesh_state.nav_query, ray_origin, search_extents, &navmesh_state.filter)

    if !recast.status_succeeded(status) || start_ref == recast.INVALID_POLY_REF {
        // If we can't find a starting polygon near the camera, try a ground-based approach
        // Project ray origin to a reasonable height range and search again
        y_offsets := [7]f32{0, -10, 10, -20, 20, -50, 50}
        for y_offset in y_offsets {
            test_origin := ray_origin
            test_origin.y += y_offset
            status, start_ref, nearest_start = detour.find_nearest_poly(navmesh_state.nav_query, test_origin, search_extents, &navmesh_state.filter)
            if recast.status_succeeded(status) && start_ref != recast.INVALID_POLY_REF {
                break
            }
        }

        if !recast.status_succeeded(status) || start_ref == recast.INVALID_POLY_REF {
            return {}, false
        }
    }

    // Perform raycast on the navmesh
    path_buffer := make([]recast.Poly_Ref, 256, context.temp_allocator)

    raycast_status, hit_info, _ := detour.raycast(navmesh_state.nav_query, start_ref, nearest_start, ray_end, &navmesh_state.filter, 0, path_buffer[:], 256)

    if recast.status_succeeded(raycast_status) {
        if hit_info.t < 1.0 {
            // Hit something
            hit_pos = nearest_start + (ray_end - nearest_start) * hit_info.t
            return hit_pos, true
        } else {
            // Ray reached the end without hitting anything
            // This means the navmesh is along the ray path
            // Find the closest point on the navmesh to the ray

            // Simple approach: sample points along the ray and find nearest navmesh point
            t_values := [9]f32{0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9}
            for t in t_values {
                sample_pos := ray_origin + ray_dir * (t * 100.0)  // Sample up to 100 units away
                sample_status, poly_ref, nearest_pos := detour.find_nearest_poly(navmesh_state.nav_query, sample_pos, [3]f32{5, 20, 5}, &navmesh_state.filter)
                if recast.status_succeeded(sample_status) && poly_ref != recast.INVALID_POLY_REF {
                    return nearest_pos, true
                }
            }
        }
    }

    return {}, false
}

// Find nearest point on navmesh from mouse position
find_navmesh_point_from_mouse :: proc(engine_ptr: ^mjolnir.Engine, mouse_x, mouse_y: f32) -> (pos: [3]f32, found: bool) {
    if navmesh_state.nav_query == nil || navmesh_state.nav_mesh == nil {
        log.error("find_navmesh_point_from_mouse: nav_query or nav_mesh is nil")
        return {}, false
    }

    // Additional logging for debugging
    log.debugf("find_navmesh_point_from_mouse: nav_query=%p, nav_mesh=%p", navmesh_state.nav_query, navmesh_state.nav_mesh)

    // Get ray from camera through mouse position
    ray_origin, ray_dir := screen_to_world_ray(engine_ptr, mouse_x, mouse_y)

    // Use multiple strategies to find the best navmesh point

    // Strategy 1: Sample along the ray at various distances
    sample_distances := [15]f32{5, 10, 15, 20, 25, 30, 35, 40, 50, 60, 70, 80, 90, 100, 150}
    best_pos: [3]f32
    best_found := false
    best_distance := f32(1e9)

    for dist in sample_distances {
        sample_pos := ray_origin + ray_dir * dist

        // Use larger search extents for better hit detection
        search_extents := [3]f32{5.0, 10.0, 5.0}
        status, poly_ref, nearest_pos := detour.find_nearest_poly(navmesh_state.nav_query, sample_pos, search_extents, &navmesh_state.filter)

        if recast.status_succeeded(status) && poly_ref != recast.INVALID_POLY_REF {
            // Check if this point is actually closer to the ray
            // Project nearest_pos onto the ray to get closest point on ray
            to_point := nearest_pos - ray_origin
            proj_dist := linalg.dot(to_point, ray_dir)
            if proj_dist > 0 {
                closest_on_ray := ray_origin + ray_dir * proj_dist
                dist_to_ray := linalg.distance(nearest_pos, closest_on_ray)

                // Prefer points that are closer to the ray and closer to the camera
                score := dist_to_ray + proj_dist * 0.01  // Small bias for closer points
                if score < best_distance {
                    best_distance = score
                    best_pos = nearest_pos
                    best_found = true
                }
            }
        }
    }

    if best_found {
        return best_pos, true
    }

    // Strategy 2: If no hit along ray, try plane intersections at various heights
    y_planes := [9]f32{0.0, 0.1, -0.1, 0.5, -0.5, 1.0, -1.0, 2.0, -2.0}

    for y_plane in y_planes {
        if abs(ray_dir.y) > 0.001 {
            t := (y_plane - ray_origin.y) / ray_dir.y
            if t > 0 && t < 200 { // Reasonable distance
                ground_pos := ray_origin + ray_dir * t
                // Find nearest navmesh point with larger search area
                search_extents := [3]f32{5.0, 10.0, 5.0}
                status, poly_ref, nearest_pos := detour.find_nearest_poly(navmesh_state.nav_query, ground_pos, search_extents, &navmesh_state.filter)
                if recast.status_succeeded(status) && poly_ref != recast.INVALID_POLY_REF {
                    return nearest_pos, true
                }
            }
        }
    }

    return {}, false
}

navmesh_mouse_moved :: proc(engine_ptr: ^mjolnir.Engine, pos, delta: [2]f64) {
    using mjolnir, geometry

    if !navmesh_state.navmesh_built {
        return
    }

    // Check if mouse moved significantly
    mouse_delta := linalg.distance([2]f32{f32(pos.x), f32(pos.y)}, navmesh_state.last_mouse_pos)
    if mouse_delta < navmesh_state.mouse_move_threshold {
        return
    }

    // Update last mouse position
    navmesh_state.last_mouse_pos = {f32(pos.x), f32(pos.y)}

    // Update hover position only when mouse moved significantly
    hover_pos, valid := find_navmesh_point_from_mouse(engine_ptr, f32(pos.x), f32(pos.y))
    navmesh_state.hover_pos = hover_pos
    navmesh_state.hover_valid = valid
}

navmesh_mouse_pressed :: proc(engine_ptr: ^mjolnir.Engine, button, action, mods: int) {
    using mjolnir, geometry

    if !navmesh_state.navmesh_built {
        return
    }

    if action != glfw.PRESS {
        return
    }

    mouse_x, mouse_y := glfw.GetCursorPos(engine_ptr.window)

    switch button {
    case glfw.MOUSE_BUTTON_LEFT:
        // Set start position
        pos, valid := find_navmesh_point_from_mouse(engine_ptr, f32(mouse_x), f32(mouse_y))
        if valid {
            navmesh_state.start_pos = pos
            navmesh_state.picking_mode = .PickingEnd
            log.infof("Start position set to: (%.2f, %.2f, %.2f) - Now click RIGHT mouse button elsewhere to set end position",
                navmesh_state.start_pos.x, navmesh_state.start_pos.y, navmesh_state.start_pos.z)

            // Update start marker (green)
            update_position_marker(engine_ptr, &navmesh_state.start_marker_handle, pos, {0, 1, 0, 1})

            // Clear existing path
            clear(&navmesh_state.path_points)
            navmesh_state.has_path = false
            update_path_visualization(&global_navmesh_engine)
        } else {
            log.warn("No valid navmesh position found at click location")
        }

    case glfw.MOUSE_BUTTON_RIGHT:
        // Set end position and find path
        if navmesh_state.picking_mode == .PickingEnd {
            pos, valid := find_navmesh_point_from_mouse(engine_ptr, f32(mouse_x), f32(mouse_y))
            if valid {
                navmesh_state.end_pos = pos
                navmesh_state.picking_mode = .PickingStart
                log.infof("End position set to: (%.2f, %.2f, %.2f) - Finding path...",
                    navmesh_state.end_pos.x, navmesh_state.end_pos.y, navmesh_state.end_pos.z)

                // Update end marker (red)
                update_position_marker(engine_ptr, &navmesh_state.end_marker_handle, pos, {1, 0, 0, 1})

                // Find path
                find_path(&global_navmesh_engine)
                update_path_visualization(&global_navmesh_engine)
            } else {
                log.warn("No valid navmesh position found at right click location")
            }
        } else {
            log.info("Please click LEFT mouse button first to set start position")
        }

    case glfw.MOUSE_BUTTON_MIDDLE:
        // Toggle camera rotation
        navmesh_state.camera_auto_rotate = !navmesh_state.camera_auto_rotate
    }
}

navmesh_update :: proc(engine_ptr: ^mjolnir.Engine, delta_time: f32) {
    using mjolnir, geometry

    // Camera control
    main_camera := get_main_camera(engine_ptr)
    if main_camera != nil {
        if navmesh_state.camera_auto_rotate {
            navmesh_state.camera_angle += delta_time * 0.2
        }

        camera_x := math.cos(navmesh_state.camera_angle) * navmesh_state.camera_distance
        camera_z := math.sin(navmesh_state.camera_angle) * navmesh_state.camera_distance
        camera_pos := [3]f32{camera_x, navmesh_state.camera_height, camera_z}

        camera_look_at(main_camera, camera_pos, {0, 0, 0}, {0, 1, 0})
    }
}

navmesh_render2d :: proc(engine_ptr: ^mjolnir.Engine, ctx: ^mu.Context) {
    using mjolnir

    if mu.window(ctx, "Navigation Mesh", {40, 40, 380, 500}, {.NO_CLOSE}) {
        mu.label(ctx, "Navigation Mesh with Mouse Picking")

        if navmesh_state.navmesh_built {
            mu.label(ctx, "Status: Built")
            if navmesh_state.poly_mesh != nil {
                mu.label(ctx, fmt.tprintf("Polygons: %d", navmesh_state.poly_mesh.npolys))
            }

            // Navigation mesh settings
            mu.label(ctx, "")
            mu.label(ctx, "NavMesh Settings:")

            // Toggle navmesh visibility
            enabled := engine_ptr.navmesh.enabled
            if .CHANGE in mu.checkbox(ctx, "Show NavMesh", &enabled) {
                engine_ptr.navmesh.enabled = enabled
            }

            // Toggle debug mode
            debug_mode := engine_ptr.navmesh.debug_mode
            if .CHANGE in mu.checkbox(ctx, "Wireframe Mode", &debug_mode) {
                engine_ptr.navmesh.debug_mode = debug_mode
            }

            // Alpha slider
            alpha := engine_ptr.navmesh.alpha
            mu.slider(ctx, &alpha, 0.0, 1.0)
            engine_ptr.navmesh.alpha = alpha
            mu.label(ctx, fmt.tprintf("Alpha: %.2f", alpha))

            // Color mode selection
            mu.label(ctx, "")
            mu.label(ctx, "Color Mode:")
            color_mode_names := [?]string{
                "Area Colors",
                "Uniform",
                "Height Based",
                "Random Colors",
                "Region Colors",
            }
            current_mode := int(engine_ptr.navmesh.color_mode)
            for name, i in color_mode_names {
                if i == current_mode {
                    mu.label(ctx, fmt.tprintf("> %s", name))
                } else {
                    if .SUBMIT in mu.button(ctx, name) {
                        engine_ptr.navmesh.color_mode = mjolnir.NavMeshColorMode(i)
                        log.infof("Changed navmesh color mode to: %s", name)
                    }
                }
            }

            // Camera control
            mu.label(ctx, "")
            mu.label(ctx, "Camera:")
            mu.checkbox(ctx, "Auto Rotate (Middle Mouse)", &navmesh_state.camera_auto_rotate)

            // Mouse picking section
            mu.label(ctx, "")
            mu.label(ctx, "Mouse Picking:")
            mu.label(ctx, fmt.tprintf("Mode: %v", navmesh_state.picking_mode))

            if navmesh_state.hover_valid {
                mu.label(ctx, fmt.tprintf("Hover: (%.1f, %.1f, %.1f)",
                    navmesh_state.hover_pos.x,
                    navmesh_state.hover_pos.y,
                    navmesh_state.hover_pos.z))
            }

            // Pathfinding info
            mu.label(ctx, "")
            mu.label(ctx, "Pathfinding:")

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
            } else {
                mu.label(ctx, "No path set")
            }

            if .SUBMIT in mu.button(ctx, "Generate Random Path (P)") {
                generate_new_path(&global_navmesh_engine)
            }

            if navmesh_state.has_path {
                if .SUBMIT in mu.button(ctx, "Clear Path (C)") {
                    clear(&navmesh_state.path_points)
                    navmesh_state.has_path = false
                    navmesh_state.picking_mode = .PickingStart
                    update_path_visualization(&global_navmesh_engine)
                    navmesh_clear_path(&engine_ptr.navmesh)
                    log.info("Path cleared")
                }
            }

            // Serialization section
            mu.label(ctx, "")
            mu.label(ctx, "Serialization:")
            mu.label(ctx, fmt.tprintf("Status: %s", navmesh_state.serialization_status))
            mu.label(ctx, fmt.tprintf("File: %s", navmesh_state.serialized_navmesh_path))

            if .SUBMIT in mu.button(ctx, "Save NavMesh (S)") {
                save_current_navmesh(&global_navmesh_engine)
            }

            if .SUBMIT in mu.button(ctx, "Load NavMesh (L)") {
                try_load_saved_navmesh(&global_navmesh_engine)
            }

            if .SUBMIT in mu.button(ctx, "Delete Saved File") {
                if os.exists(navmesh_state.serialized_navmesh_path) {
                    os.remove(navmesh_state.serialized_navmesh_path)
                    navmesh_state.serialization_status = "Saved file deleted"
                    log.infof("Deleted saved navmesh file: %s", navmesh_state.serialized_navmesh_path)
                } else {
                    navmesh_state.serialization_status = "No file to delete"
                }
            }

            // Controls help
            mu.label(ctx, "")
            mu.label(ctx, "Controls:")
            mu.label(ctx, "Left Click - Set Start")
            mu.label(ctx, "Right Click - Set End & Find Path")
            mu.label(ctx, "Middle Click - Toggle Auto Rotate")
            mu.label(ctx, "C - Clear Path")
            mu.label(ctx, "D - Cycle Color Modes")
            mu.label(ctx, "L - Load NavMesh")
            mu.label(ctx, "P - Generate Random Path")
            mu.label(ctx, "R - Rebuild NavMesh")
            mu.label(ctx, "S - Save NavMesh")
            mu.label(ctx, "V - Toggle NavMesh")
            mu.label(ctx, "W - Toggle Wireframe")

        } else {
            mu.label(ctx, "Status: Not Built")
            if .SUBMIT in mu.button(ctx, "Build NavMesh") {
                build_navmesh(engine_ptr)
            }
        }
    }
}

navmesh_key_pressed :: proc(engine_ptr: ^mjolnir.Engine, key, action, mods: int) {
    using mjolnir, geometry

    if action != glfw.PRESS do return

    switch key {
    case glfw.KEY_R:
        // Rebuild navigation mesh
        log.info("Rebuilding navigation mesh...")
        build_navmesh(engine_ptr)

    case glfw.KEY_V:
        // Toggle navmesh visibility
        engine_ptr.navmesh.enabled = !engine_ptr.navmesh.enabled
        log.infof("NavMesh visibility: %v", engine_ptr.navmesh.enabled)

    case glfw.KEY_W:
        // Toggle wireframe mode
        engine_ptr.navmesh.debug_mode = !engine_ptr.navmesh.debug_mode
        log.infof("NavMesh wireframe: %v", engine_ptr.navmesh.debug_mode)

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
        // Clear path
        clear(&navmesh_state.path_points)
        navmesh_state.has_path = false
        navmesh_state.picking_mode = .PickingStart
        update_path_visualization(&global_navmesh_engine)
        navmesh_clear_path(&engine_ptr.navmesh)
        log.info("Path cleared")

    case glfw.KEY_D:
        // Cycle through color modes with D key (Debug colors)
        current_mode := int(engine_ptr.navmesh.color_mode)
        current_mode = (current_mode + 1) % 5  // We have 5 color modes now
        engine_ptr.navmesh.color_mode = mjolnir.NavMeshColorMode(current_mode)
        mode_names := [5]string{"Area Colors", "Uniform", "Height Based", "Random Colors", "Region Colors"}
        log.infof("NavMesh color mode changed to: %s", mode_names[current_mode])

    case glfw.KEY_P:
        // Generate new path
        if navmesh_state.navmesh_built {
            log.info("Generating new random path...")
            generate_new_path(&global_navmesh_engine)
        } else {
            log.warn("Build navigation mesh first (press R)")
        }

    case glfw.KEY_SPACE:
        // Generate new path (alternative key)
        if navmesh_state.navmesh_built {
            log.info("Generating new random path...")
            generate_new_path(&global_navmesh_engine)
        } else {
            log.warn("Build navigation mesh first (press R)")
        }

    case glfw.KEY_S:
        // Save navigation mesh
        if navmesh_state.navmesh_built && navmesh_state.nav_mesh != nil {
            log.info("Saving navigation mesh...")
            save_current_navmesh(&global_navmesh_engine)
        } else {
            log.warn("No navigation mesh to save - build one first (press R)")
        }

    case glfw.KEY_L:
        // Load navigation mesh
        log.info("Loading navigation mesh...")
        try_load_saved_navmesh(&global_navmesh_engine)
    }
}

// Analyze connectivity from Detour's perspective
analyze_detour_connectivity :: proc(nav_mesh: ^detour.Nav_Mesh) {
    using detour

    // Get the first tile (solo mesh)
    tile := get_tile_at(nav_mesh, 0, 0, 0)
    if tile == nil || tile.header == nil {
        log.error("Failed to get nav mesh tile")
        return
    }

    log.infof("Detour tile has %d polygons", tile.header.poly_count)

    // Build connectivity graph using BFS
    visited := make([]bool, tile.header.poly_count, context.temp_allocator)
    components := make([dynamic]int, context.temp_allocator)

    for start_poly in 0..<tile.header.poly_count {
        if visited[start_poly] do continue

        // Start a new component
        component_size := 0
        stack := make([dynamic]int, context.temp_allocator)
        append(&stack, int(start_poly))

        for len(stack) > 0 {
            current := pop(&stack)
            if visited[current] do continue
            visited[current] = true
            component_size += 1

            // Check all neighbors
            poly := &tile.polys[current]
            for i in 0..<poly.vert_count {
                // Check neighbor through edge
                if poly.neis[i] != 0 {
                    // Internal edge - neighbor within same tile
                    if poly.neis[i] < 0x8000 {
                        neighbor_idx := int(poly.neis[i] - 1)  // Convert to 0-based
                        if neighbor_idx >= 0 && neighbor_idx < int(tile.header.poly_count) && !visited[neighbor_idx] {
                            append(&stack, neighbor_idx)
                        }
                    }
                }

                // Also check through links
                link_idx := poly.first_link
                for link_idx != recast.DT_NULL_LINK {
                    link := &tile.links[link_idx]
                    if link.ref != 0 {
                        // Extract polygon index from reference
                        poly_idx := int(link.ref & 0xFFFF)  // Mask to get poly ID
                        if poly_idx < int(tile.header.poly_count) && !visited[poly_idx] {
                            append(&stack, poly_idx)
                        }
                    }
                    link_idx = link.next
                }
            }
        }

        append(&components, component_size)
    }

    log.infof("Found %d connected components in Detour NavMesh:", len(components))
    for i, size in components {
        log.infof("  Component %d: %d polygons", i, size)
    }

    // Test pathfinding between corners
    test_corner_connectivity(nav_mesh)
}

// Test pathfinding between corners to check connectivity
test_corner_connectivity :: proc(nav_mesh: ^detour.Nav_Mesh) {
    using detour

    // Create navigation query
    nav_query := new(Nav_Mesh_Query)
    defer free(nav_query)

    query_status := nav_mesh_query_init(nav_query, nav_mesh, 2048)
    if recast.status_failed(query_status) {
        log.error("Failed to create navigation query for corner test")
        return
    }

    // Initialize filter
    filter: Query_Filter
    query_filter_init(&filter)

    // Test corners
    test_points := [][3]f32{
        {-20.0, 0.0, -20.0},  // Bottom-left
        {20.0, 0.0, -20.0},   // Bottom-right
        {-20.0, 0.0, 20.0},   // Top-left
        {20.0, 0.0, 20.0},    // Top-right
    }

    names := []string{"Bottom-left", "Bottom-right", "Top-left", "Top-right"}

    extents := [3]f32{5.0, 5.0, 5.0}
    refs: [4]recast.Poly_Ref
    nearest: [4][3]f32

    // Find nearest polygons for each test point
    for i in 0..<4 {
        status, ref, pt := find_nearest_poly(nav_query, test_points[i], extents, &filter)
        refs[i] = ref
        nearest[i] = pt
        if recast.status_succeeded(status) && refs[i] != 0 {
            log.infof("%s: Found poly 0x%x at (%.1f, %.1f, %.1f)",
                names[i], refs[i], nearest[i][0], nearest[i][1], nearest[i][2])
        } else {
            log.warnf("%s: Failed to find nearest poly", names[i])
            refs[i] = 0
        }
    }

    // Test paths between all pairs
    log.info("Path connectivity matrix:")
    log.info("        BL    BR    TL    TR")
    for i in 0..<4 {
        fmt.printf("%s: ", names[i])
        for j in 0..<4 {
            if i == j {
                fmt.printf("  -   ")
            } else if refs[i] != 0 && refs[j] != 0 {
                path: [256]recast.Poly_Ref
                status, pc := find_path(nav_query, refs[i], refs[j], nearest[i], nearest[j],
                                  &filter, path[:], 256)
                if recast.status_succeeded(status) && pc > 1 {
                    fmt.printf(" YES  ")
                } else {
                    fmt.printf(" NO   ")
                }
            } else {
                fmt.printf(" N/A  ")
            }
        }
        fmt.println()
    }
}

// Try to load previously saved navigation mesh
try_load_saved_navmesh :: proc(engine_ptr: ^mjolnir.Engine) {
    using mjolnir

    if !os.exists(navmesh_state.serialized_navmesh_path) {
        navmesh_state.serialization_status = "No saved navmesh found"
        return
    }

    log.infof("=== LOADING SAVED NAVIGATION MESH ===")
    log.infof("Loading from: %s", navmesh_state.serialized_navmesh_path)

    // Load navigation mesh from file
    loaded_nav_mesh, loaded_query, load_ok := detour.load_navmesh_for_runtime(navmesh_state.serialized_navmesh_path)
    if !load_ok {
        navmesh_state.serialization_status = "Failed to load saved navmesh"
        log.error("Failed to load saved navigation mesh")
        return
    }

    // Clean up existing navigation system
    if navmesh_state.nav_query != nil {
        detour.pathfinding_context_destroy(&navmesh_state.nav_query.pf_context)
        free(navmesh_state.nav_query)
    }
    if navmesh_state.nav_mesh != nil {
        detour.nav_mesh_destroy(navmesh_state.nav_mesh)
        free(navmesh_state.nav_mesh)
    }

    // Use loaded navigation mesh
    navmesh_state.nav_mesh = loaded_nav_mesh
    navmesh_state.nav_query = loaded_query

    // Initialize filter
    detour.query_filter_init(&navmesh_state.filter)

    // Build visualization from loaded mesh
    success := build_visualization_from_detour_mesh(engine_ptr, loaded_nav_mesh)
    if !success {
        log.error("Failed to build visualization from loaded mesh")
        navmesh_state.serialization_status = "Loaded but visualization failed"
        return
    }

    navmesh_state.navmesh_built = true
    navmesh_state.serialization_status = "Loaded successfully from file"
}

// Save current navigation mesh to file
save_current_navmesh :: proc(engine_ptr: ^mjolnir.Engine) {
    using mjolnir

    if navmesh_state.nav_mesh == nil {
        navmesh_state.serialization_status = "No navmesh to save"
        log.error("No navigation mesh to save")
        return
    }

    save_ok := detour.save_navmesh_to_file(navmesh_state.nav_mesh, navmesh_state.serialized_navmesh_path)
    if !save_ok {
        navmesh_state.serialization_status = "Failed to save navmesh"
        log.error("Failed to save navigation mesh")
        return
    }

    navmesh_state.serialization_status = "Saved successfully to file"
    log.info("Saved navigation mesh to file")
}

// Build visualization from Detour navigation mesh (for loaded meshes)
build_visualization_from_detour_mesh :: proc(engine_ptr: ^mjolnir.Engine, nav_mesh: ^detour.Nav_Mesh) -> bool {
    using mjolnir


    tile := detour.get_tile_at(nav_mesh, 0, 0, 0)
    if tile == nil || tile.header == nil {
        log.error("Failed to get navigation mesh tile for visualization")
        return false
    }


    navmesh_vertices := make([dynamic]mjolnir.NavMeshVertex, 0, int(tile.header.vert_count))
    indices := make([dynamic]u32, 0, int(tile.header.poly_count) * 3)

    for i in 0..<tile.header.vert_count {
        pos := tile.verts[i]
        append(&navmesh_vertices, mjolnir.NavMeshVertex{
            position = pos,
            color = {0.0, 0.8, 0.2, 0.6},
            normal = {0, 1, 0},
        })
    }
    for i in 0..<tile.header.poly_count {
        poly := &tile.polys[i]
        vert_count := int(poly.vert_count)

        if vert_count < 3 do continue

        poly_seed := u32(i * 17 + 23)
        hue := f32((poly_seed * 137) % 360)
        poly_color := [4]f32{
            0.5 + 0.5 * math.sin(hue * math.PI / 180.0),
            0.5 + 0.5 * math.sin((hue + 120) * math.PI / 180.0),
            0.5 + 0.5 * math.sin((hue + 240) * math.PI / 180.0),
            0.6,
        }
        for j in 0..<vert_count {
            if int(poly.verts[j]) < len(navmesh_vertices) {
                navmesh_vertices[poly.verts[j]].color = poly_color
            }
        }
        for j in 1..<vert_count-1 {
            append(&indices, u32(poly.verts[0]))
            append(&indices, u32(poly.verts[j]))
            append(&indices, u32(poly.verts[j+1]))
        }
    }

    defer delete(navmesh_vertices)
    defer delete(indices)

    renderer := &engine_ptr.navmesh
    renderer.vertex_count = u32(len(navmesh_vertices))
    renderer.index_count = u32(len(indices))

    if renderer.vertex_count == 0 || renderer.index_count == 0 {
        log.warn("Navigation mesh has no renderable geometry")
        return false
    }

    if renderer.vertex_count > 16384 {
        log.errorf("Too many vertices (%d) for buffer size (16384)", renderer.vertex_count)
        return false
    }
    if renderer.index_count > 32768 {
        log.errorf("Too many indices (%d) for buffer size (32768)", renderer.index_count)
        return false
    }

    vertex_result := gpu.data_buffer_write(&renderer.vertex_buffer, navmesh_vertices[:])
    if vertex_result != .SUCCESS {
        log.error("Failed to upload navigation mesh vertex data")
        return false
    }

    index_result := gpu.data_buffer_write(&renderer.index_buffer, indices[:])
    if index_result != .SUCCESS {
        log.error("Failed to upload navigation mesh index data")
        return false
    }
    renderer.enabled = true
    renderer.debug_mode = false
    renderer.alpha = 0.6
    renderer.height_offset = 0.05
    renderer.color_mode = .Random_Colors


    return true
}

// Analyze detailed polygon connections
analyze_detailed_connections :: proc(nav_mesh: ^detour.Nav_Mesh) {
    using detour

    log.info("=== DETAILED CONNECTION ANALYSIS ===")

    // Get the first tile (solo mesh)
    tile := get_tile_at(nav_mesh, 0, 0, 0)
    if tile == nil || tile.header == nil {
        log.error("Failed to get nav mesh tile")
        return
    }

    log.infof("Analyzing connections for %d polygons", tile.header.poly_count)

    // Analyze first 10 polygons in detail
    for i in 0..<min(10, int(tile.header.poly_count)) {
        poly := &tile.polys[i]
        log.infof("\nPolygon %d (ref=0x%x):", i, get_poly_ref_base(nav_mesh, tile) | recast.Poly_Ref(i))
        log.infof("  Vertex count: %d", poly.vert_count)

        // Show vertices
        fmt.printf("  Vertices: ")
        for v in 0..<poly.vert_count {
            fmt.printf("%d ", poly.verts[v])
        }
        fmt.println()

        // Show edge neighbors
        fmt.printf("  Edge neighbors: ")
        for e in 0..<poly.vert_count {
            if poly.neis[e] != 0 {
                if poly.neis[e] & 0x8000 != 0 {
                    // External link
                    fmt.printf("[%d]=EXT(0x%x) ", e, poly.neis[e])
                } else {
                    // Internal neighbor
                    neighbor_idx := int(poly.neis[e] - 1)
                    fmt.printf("[%d]=%d ", e, neighbor_idx)
                }
            } else {
                fmt.printf("[%d]=WALL ", e)
            }
        }
        fmt.println()

        // Count links
        link_count := 0
        link_idx := poly.first_link
        for link_idx != recast.DT_NULL_LINK {
            link_count += 1
            link := &tile.links[link_idx]
            link_idx = link.next
        }
        log.infof("  Link count: %d", link_count)

        if link_count > 0 {
            fmt.printf("  Links: ")
            link_idx = poly.first_link
            for link_idx != recast.DT_NULL_LINK {
                link := &tile.links[link_idx]
                fmt.printf("(edge=%d,ref=0x%x) ", link.edge, link.ref)
                link_idx = link.next
            }
            fmt.println()
        }
    }
}
