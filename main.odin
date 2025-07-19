package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:slice"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/gpu"
import "mjolnir/navigation"
import "mjolnir/resource"
import "vendor:glfw"
import mu "vendor:microui"
import vk "vendor:vulkan"

LIGHT_COUNT :: 5
ALL_SPOT_LIGHT :: false
ALL_POINT_LIGHT :: false
light_handles: [LIGHT_COUNT]mjolnir.Handle
light_cube_handles: [LIGHT_COUNT]mjolnir.Handle
ground_mat_handle: mjolnir.Handle
hammer_handle: mjolnir.Handle
engine: mjolnir.Engine
forcefield_handle: mjolnir.Handle
forcefield_node: ^mjolnir.Node

// Portal render target and related data
portal_render_target_handle: mjolnir.Handle
portal_material_handle: mjolnir.Handle
portal_quad_handle: mjolnir.Handle

// Camera controllers
orbit_controller: geometry.CameraController
free_controller: geometry.CameraController
current_controller: ^geometry.CameraController
tab_was_pressed: bool

// Navigation system
navmesh_builder: navigation.NavMeshBuilder
navmesh: navigation.NavMesh
nav_debug: mjolnir.NavigationDebug
nav_query: navigation.PathQuery
current_path: [][3]f32
start_pos: [3]f32 = {0, 0.1, -4}   // South of obstacle
end_pos: [3]f32 = {0, 0.1, 4}     // North of obstacle
nav_debug_enabled: bool = true

// Helper function to check if a position intersects with the test obstacle
position_in_obstacle :: proc(pos: [3]f32) -> bool {
  x, y, z := pos.x, pos.y, pos.z

  // Test obstacle: 10x2x2 box centered at origin (2x2x2 cube scaled by 5x1x1)
  // Box extends from (-5, 0, -1) to (5, 2, 1)
  if x >= -5 && x <= 5 && z >= -1 && z <= 1 && y >= 0 && y <= 2 {
    return true
  }

  return false
}

main :: proc() {
  context.logger = log.create_console_logger()
  engine.setup_proc = setup
  engine.update_proc = update
  engine.render2d_proc = render_2d
  engine.key_press_proc = on_key_pressed
  engine.post_lighting_render_proc = post_lighting_render
  mjolnir.run(&engine, 1280, 720, "Mjolnir Odin")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("Setup function called!")
  goldstar_texture_handle, _, _ := mjolnir.create_texture_from_path(
    &engine.gpu_context,
    &engine.warehouse,
    "assets/gold-star.png",
  )
  plain_material_handle, _, _ := create_material(&engine.warehouse)
  wireframe_material_handle, _, _ := create_wireframe_material(
    &engine.warehouse,
  )
  goldstar_material_handle, goldstar_material, _ :=
    create_transparent_material(&engine.warehouse, {.ALBEDO_TEXTURE})
  goldstar_material.albedo = goldstar_texture_handle
  cube_geom := make_cube()
  cube_mesh_handle, _, _ := create_mesh(
    &engine.gpu_context,
    &engine.warehouse,
    cube_geom,
  )
  sphere_mesh_handle, _, _ := create_mesh(
    &engine.gpu_context,
    &engine.warehouse,
    make_sphere(),
  )
  // Create ground plane
  ground_albedo_handle, _, _ := create_texture_from_path(
    &engine.gpu_context,
    &engine.warehouse,
    "assets/t_brick_floor_002_diffuse_1k.jpg",
  )
  ground_mat_handle, _, _ = create_material(
    &engine.warehouse,
    {.ALBEDO_TEXTURE},
    ground_albedo_handle,
  )
  ground_mesh_handle, _, _ := create_mesh(
    &engine.gpu_context,
    &engine.warehouse,
    make_quad(),
  )
  cone_mesh_handle, _, _ := create_mesh(
    &engine.gpu_context,
    &engine.warehouse,
    make_cone(),
  )
  if true {
    log.info("spawning test obstacle: 5x2x5 box")

    // Single obstacle: 5x2x5 box centered at (5,0,5)
    obstacle_material_handle, _ := create_material(
      &engine.warehouse,
      metallic_value = 0.0,
      roughness_value = 0.8,
    ) or_else {}

    // Spawn obstacle cube
    _, obstacle_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle = cube_mesh_handle,
        material = obstacle_material_handle,
        cast_shadow = true,
      },
    )

    // Position and scale obstacle - centered at origin
    translate(&obstacle_node.transform, 0, 0.5, 0)  // Lift up to avoid ground intersection
    scale_xyz(&obstacle_node.transform, 5, 1, 1)  // Scale to 5x1x1 (width x height x depth)
  }
  if true {
    log.info("spawning ground plane")
    // Ground plane: 20x20 at y=0 (2x2 quad scaled by 10)
    _, ground_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
      },
    )
    scale(&ground_node.transform, 10)  // 10x10 scale, centered at origin
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Mjolnir.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      hammer_handle = handle
      node := resource.get(engine.scene.nodes, handle) or_continue
      translate(&node.transform, 3, 1, -2)
      scale(&node.transform, 0.2)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/DamagedHelmet.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      helm := resource.get(engine.scene.nodes, handle) or_continue
      translate(&helm.transform, 0, 1, 3)
      scale(&helm.transform, 0.5)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Suzanne.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for handle in gltf_nodes {
      monkey := resource.get(engine.scene.nodes, handle) or_continue
      translate(&monkey.transform, -3, 1, -2)
    }
  }
  if true {
    log.info("loading GLTF...")
    gltf_nodes := load_gltf(engine, "assets/Warrior.glb") or_else {}
    log.infof("Loaded GLTF nodes: %v", gltf_nodes)
    for armature in gltf_nodes {
      armature_ptr := resource.get(engine.scene.nodes, armature) or_continue
      for i in 1 ..< len(armature_ptr.children) {
        play_animation(engine, armature_ptr.children[i], "idle")
      }
      translate(&armature_ptr.transform, 0, 0, 1)
    }
  }
  if true {
    log.infof("creating %d lights", LIGHT_COUNT)
    // Create lights and light cubes
    for i in 0 ..< LIGHT_COUNT {
      color := [4]f32 {
        math.sin(f32(i)),
        math.cos(f32(i)),
        math.sin(f32(i)),
        1.0,
      }
      light: ^Node
      should_make_spot_light := i % 2 != 0
      if ALL_SPOT_LIGHT {
        should_make_spot_light = true
      } else if ALL_POINT_LIGHT {
        should_make_spot_light = false
      }
      if should_make_spot_light {
        light_handles[i], light = spawn(
          &engine.scene,
          SpotLightAttachment {
            color = color,
            angle = math.PI * 0.4,
            radius = 10,
            cast_shadow = true,
          },
        )
        rotate(&light.transform, math.PI * 0.2, linalg.VECTOR3F32_X_AXIS)
      } else {
        light_handles[i], light = spawn(
          &engine.scene,
          PointLightAttachment{color = color, radius = 10, cast_shadow = true},
        )
      }
      translate(&light.transform, 6, 2, -1)
      cube_node: ^Node
      light_cube_handles[i], cube_node = spawn_child(
        &engine.scene,
        light_handles[i],
        MeshAttachment {
          handle = cube_mesh_handle,
          material = plain_material_handle,
          cast_shadow = false,
        },
      )
      scale(&cube_node.transform, 0.1)
    }
    // spawn(
    //   &engine.scene,
    //   DirectionalLightAttachment {
    //     color = {0.3, 0.3, 0.3, 1.0},
    //     cast_shadow = true,
    //   },
    // )
  }

  if false {
    // effect_add_bloom(&engine.postprocess, 0.8, 0.5, 16.0)
    // Create a bright white ball to test bloom effect
    bright_material_handle, _, _ := create_material(
      &engine.warehouse,
      emissive_value = 30.0,
    )
    _, bright_ball_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle      = sphere_mesh_handle,
        material    = bright_material_handle,
        cast_shadow = false, // Emissive objects don't need shadows
      },
    )
    translate(&bright_ball_node.transform, x = 1.0) // Position it above the ground
    scale(&bright_ball_node.transform, 0.2) // Make it a reasonable size
  }

  if true {
    black_circle_texture_handle, _, _ := mjolnir.create_texture_from_path(
      &engine.gpu_context,
      &engine.warehouse,
      "assets/black-circle.png",
    )
    psys_handle1, _ := spawn_at(
      &engine.scene,
      {-2.0, 1.9, 0.3},
      mjolnir.ParticleSystemAttachment {
        bounding_box = geometry.Aabb{min = {-1, -1, -1}, max = {1, 1, 1}},
        texture_handle = goldstar_texture_handle,
      },
    )
    spawn_child(
      &engine.scene,
      psys_handle1,
      EmitterAttachment {
        emission_rate = 7,
        particle_lifetime = 5.0,
        position_spread = 1.5,
        initial_velocity = {0, -0.1, 0, 0},
        velocity_spread = 0.1,
        color_start = {1, 1, 0, 1}, // Yellow particles
        color_end = {1, 0.5, 0, 0},
        size_start = 200.0,
        size_end = 100.0,
        weight = 0.1,
        weight_spread = 0.05,
        texture_handle = goldstar_texture_handle,
        enabled = true,
        bounding_box = geometry.Aabb{min = {-2, -2, -2}, max = {2, 2, 2}},
      },
    )
    psys_handle2, _ := spawn_at(
      &engine.scene,
      {2.0, 1.9, 0.3},
      mjolnir.ParticleSystemAttachment {
        bounding_box = geometry.Aabb{min = {-1, -1, -1}, max = {1, 1, 1}},
        texture_handle = black_circle_texture_handle,
      },
    )
    // Create an emitter for the second particle system
    spawn_child(
      &engine.scene,
      psys_handle2,
      EmitterAttachment {
        emission_rate = 7,
        particle_lifetime = 3.0,
        position_spread = 0.3,
        initial_velocity = {0, 0.2, 0, 0},
        velocity_spread = 0.15,
        color_start = {0, 0, 1, 1}, // Blue particles
        color_end = {0, 1, 1, 0},
        size_start = 350.0,
        size_end = 175.0,
        weight = 0.1,
        weight_spread = 0.3,
        texture_handle = black_circle_texture_handle,
        enabled = true,
        bounding_box = geometry.Aabb{min = {-1, -1, -1}, max = {1, 1, 1}},
      },
    )
    // Create a force field that affects both particle systems
    forcefield_handle, forcefield_node = spawn_child(
      &engine.scene,
      psys_handle1, // Attach to first particle system
      mjolnir.ForceFieldAttachment {
        tangent_strength = 2.0,
        strength = 20.0,
        area_of_effect = 5.0,
      },
    )
    geometry.translate(&forcefield_node.transform, x = 5.0, y = 4.0, z = 0.0)
    _, forcefield_visual := spawn_child(
      &engine.scene,
      forcefield_handle,
      MeshAttachment {
        handle = sphere_mesh_handle,
        material = goldstar_material_handle,
        cast_shadow = false,
      },
    )
    geometry.scale(&forcefield_visual.transform, 0.2)
  }
  // effect_add_fog(&engine.postprocess, {0.4, 0.0, 0.8}, 0.02, 5.0, 20.0)
  // effect_add_bloom(&engine.postprocess)
  // effect_add_crosshatch(&engine.postprocess, {1280, 720})
  // effect_add_blur(&engine.postprocess, 18.0)
  // effect_add_tonemap(&engine.postprocess, 1.5, 1.3)
  // effect_add_dof(&engine.postprocess)
  // effect_add_grayscale(&engine.postprocess, 0.9)
  // effect_add_outline(&engine.postprocess, 2.0, {1.0, 0.0, 0.0})
  // Initialize camera controllers
  geometry.setup_camera_controller_callbacks(engine.window)
  main_camera := mjolnir.get_main_camera(engine)
  orbit_controller = geometry.camera_controller_orbit_init(
    engine.window,
    {0, 0, 0}, // dummy target
    1.0, // dummy distance
    0, // dummy yaw
    0, // dummy pitch
  )
  // Initialize free controller
  free_controller = geometry.camera_controller_free_init(
    engine.window,
    5.0,
    2.0,
  )
  if main_camera != nil {
    geometry.camera_controller_sync(&orbit_controller, main_camera)
    geometry.camera_controller_sync(&free_controller, main_camera)
  }
  current_controller = &orbit_controller
  // Portal setup
  if true {
    log.info("Setting up portal...")

    // Create portal render target via global pool
    portal_render_target: ^mjolnir.RenderTarget
    portal_render_target_handle, portal_render_target = resource.alloc(
      &engine.warehouse.render_targets,
    )
    render_target_init(
      portal_render_target,
      &engine.gpu_context,
      &engine.warehouse,
      512, // Portal texture resolution
      512,
      .R8G8B8A8_UNORM, // Color format
      .D32_SFLOAT, // Depth format
    )
    log.infof(
      "Portal render target created: handle=%v, extent=%v",
      portal_render_target_handle,
      portal_render_target.extent,
    )

    // Configure the portal camera to look down from above at a steep angle
    portal_camera := render_target_get_camera(
      &engine.warehouse,
      portal_render_target,
    )
    geometry.camera_look_at(portal_camera, {5, 15, 7}, {0, 0, 0}, {0, 1, 0})
    // Create portal material (albedo only)
    portal_material: ^mjolnir.Material
    portal_material_handle, portal_material, _ = create_material(
      &engine.warehouse,
      {.ALBEDO_TEXTURE},
    )
    // We'll set the texture handle after first render
    log.infof(
      "Portal material created with handle: %v",
      portal_material_handle,
    )
    // Create portal quad mesh and spawn it
    portal_quad_geom := make_quad()
    portal_quad_mesh_handle, _, _ := create_mesh(
      &engine.gpu_context,
      &engine.warehouse,
      portal_quad_geom,
    )
    _, portal_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle = portal_quad_mesh_handle,
        material = portal_material_handle,
        cast_shadow = false,
      },
    )
    // Position the portal vertically
    translate(&portal_node.transform, 0, 3, -5)
    rotate(&portal_node.transform, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
    scale(&portal_node.transform, 2.0)
  }

  // Build navigation mesh from scene geometry
  build_navigation_from_scene(engine)

  log.info("setup complete")
}

// Build navigation mesh from the test scene (10x10 ground with single 5x2 obstacle)
build_navigation_from_scene :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry

  log.info("=== Building Test Navigation Scene ===")
  log.info("Scene: 15x15 ground with 5x2x5 obstacle in center")

  vertices_list := make([dynamic][3]f32)
  indices_list := make([dynamic]u32)
  areas_list := make([dynamic]u8)
  defer delete(vertices_list)
  defer delete(indices_list)
  defer delete(areas_list)

  // Ground: 20x20 plane at y=0, centered at origin (2x2 quad scaled by 10)
  ground_verts := [][3]f32{
    {-10, 0, -10}, // 0
    {10, 0, -10},  // 1
    {10, 0, 10},   // 2
    {-10, 0, 10},  // 3
  }

  ground_indices := []u32{
    0, 1, 2,  // Triangle 1
    0, 2, 3,  // Triangle 2
  }

  // Add ground vertices and indices
  for vert in ground_verts {
    append(&vertices_list, vert)
  }
  for idx in ground_indices {
    append(&indices_list, idx)
  }
  // Add ground triangle areas (one per triangle, not per index)
  for _ in 0..<len(ground_indices)/3 {
    append(&areas_list, navigation.WALKABLE_AREA)
  }

  log.infof("Ground: %d vertices, %d triangles", len(ground_verts), len(ground_indices)/3)

  // Obstacle: 10x2x2 box centered at origin (2x2x2 cube scaled by 5x1x1)
  // Box extends from (-5, 0, -1) to (5, 2, 1)
  obstacle_verts := [][3]f32{
    // Bottom face (y=0)
    {-5, 0, -1}, // 4
    {5, 0, -1},  // 5
    {5, 0, 1},   // 6
    {-5, 0, 1},  // 7

    // Top face (y=2)
    {-5, 2, -1}, // 8
    {5, 2, -1},  // 9
    {5, 2, 1},   // 10
    {-5, 2, 1},  // 11
  }

  obstacle_indices := []u32{
    // Bottom face
    4, 6, 5,  4, 7, 6,
    // Top face
    8, 9, 10,  8, 10, 11,
    // Front face (z=4)
    4, 5, 9,  4, 9, 8,
    // Back face (z=6)
    6, 11, 10,  6, 7, 11,
    // Left face (x=2.5)
    7, 8, 11,  7, 4, 8,
    // Right face (x=7.5)
    5, 10, 9,  5, 6, 10,
  }

  // Add obstacle vertices and indices (offset indices by ground vertex count)
  ground_vert_count := u32(len(ground_verts))
  for vert in obstacle_verts {
    append(&vertices_list, vert)
  }
  for idx in obstacle_indices {
    append(&indices_list, idx)
  }
  // Add obstacle triangle areas (one per triangle, not per index)
  for _ in 0..<len(obstacle_indices)/3 {
    append(&areas_list, navigation.NULL_AREA)  // Non-walkable
  }

  log.infof("Obstacle: %d vertices, %d triangles", len(obstacle_verts), len(obstacle_indices)/3)
  log.infof("Total scene: %d vertices, %d triangles", len(vertices_list), len(indices_list)/3)

  // Convert to input format for new navigation system
  input := navigation.NavMeshInput{
    vertices = vertices_list[:],
    indices = indices_list[:],
    areas = areas_list[:],
  }

  // Use reasonable configuration for 10x2x2 obstacle on 20x20 ground
  config := mjolnir.default_navmesh_config()
  config.cell_size = 0.3          // Reasonable resolution
  config.agent_radius = 0.1       // Small agent expansion
  config.agent_height = 1.5       // Standard agent height
  config.agent_max_climb = 0.5    // Standard climb value

  // Build the navigation mesh
  log.info("Building navigation mesh...")
  ok: bool
  navmesh, ok = mjolnir.build_navmesh(input, config)

  if !ok {
    log.error("Failed to build navigation mesh from scene!")
    return
  }

  log.info("Navigation mesh built successfully!")

  // Add obstacles for scene objects
  log.info("Adding scene obstacles...")
  add_scene_obstacles_to_navmesh(engine)
  log.info("Scene obstacles added")

  // Initialize debug visualization
  log.info("Initializing navigation debug...")
  if !mjolnir.navigation_debug_init(&nav_debug, engine, &navmesh, &navmesh_builder) {
    log.error("Failed to initialize navigation debug")
  } else {
    log.info("Navigation debug initialized")
    // Start with final mesh visualization (regions mode has a bug)
    nav_debug.vis_mode = .FINAL_MESH
    log.info("Set visualization mode to FINAL_MESH - press V to cycle through modes")

    // Set custom colors for better visibility
    colors := NavMeshColors{
      mesh        = {0.0, 0.8, 0.0, 0.3}, // Semi-transparent green
      bounds      = {1.0, 1.0, 1.0, 1.0}, // White wireframe
      path_line   = {1.0, 1.0, 0.0, 1.0}, // Yellow path
      start_point = {0.0, 0.0, 1.0, 1.0}, // Blue start
      end_point   = {1.0, 1.0, 0.0, 1.0}, // Yellow end
    }
    navigation_debug_set_colors(&nav_debug, colors)

    // Initialize the debug renderer with swapchain format
    color_format := engine.swapchain.format.format
    depth_format := vk.Format.D32_SFLOAT

    if !navigation_debug_init_renderer(
      &nav_debug,
      engine,
      color_format,
      depth_format,
    ) {
      log.error("Failed to initialize navigation debug renderer")
    }
  }
}

// Add obstacles to navigation mesh for scene objects
add_scene_obstacles_to_navmesh :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry

  // TODO: Implement dynamic obstacles when API is available
  log.info("Dynamic obstacles not yet implemented")
}

// Clean up navigation resources
cleanup_navigation :: proc() {
  // Destroy navigation mesh
  navigation.destroy(&navmesh)

  // Clean up path query
  navigation.query_deinit(&nav_query)

  // Clean up debug resources
  mjolnir.navigation_debug_deinit(&nav_debug, &engine)

  // Clean up current path
  if len(current_path) > 0 {
    delete(current_path)
  }
}

// Add a new obstacle when an object is spawned
add_navigation_obstacle :: proc(pos: [3]f32, radius: f32, height: f32 = 3.0) {
  // TODO: Implement when dynamic obstacle API is available
}

// Find a path between two points
find_navigation_path :: proc(start, end: [3]f32) -> bool {
  // Clear previous path
  if len(current_path) > 0 {
    delete(current_path)
    current_path = nil
  }

  // Validate positions
  if position_in_obstacle(start) {
    log.warnf("Start position [%.1f, %.1f, %.1f] is inside an obstacle!", start.x, start.y, start.z)
  }
  if position_in_obstacle(end) {
    log.warnf("End position [%.1f, %.1f, %.1f] is inside an obstacle!", end.x, end.y, end.z)
  }

  log.infof("Pathfinding from [%.1f, %.1f, %.1f] to [%.1f, %.1f, %.1f]",
            start.x, start.y, start.z, end.x, end.y, end.z)

  // Initialize query if needed
  if nav_query.mesh == nil {
    nav_query = navigation.query_init(&navmesh)
  }

  // Find path
  path, ok := navigation.find_path(&nav_query, start, end)

  if ok && len(path) > 0 {
    // Use the path directly
    current_path = path

    // Update debug visualization
    mjolnir.navigation_debug_set_path(&nav_debug, &engine, current_path, start)

    log.infof("Found path with %d waypoints", len(current_path))
    return true
  }

  if len(path) > 0 {
    delete(path)
  }

  log.warn("Failed to find path")
  return false
}


post_lighting_render :: proc(
  engine: ^mjolnir.Engine,
  command_buffer: vk.CommandBuffer,
) {
  using mjolnir, geometry

  // Render navigation debug overlay after all lighting is complete
  if nav_debug_enabled && nav_debug.enabled {
    main_camera := mjolnir.get_main_camera(engine)
    if main_camera != nil {
      // Get camera matrices properly
      view_matrix, proj_matrix := geometry.camera_calculate_matrices(main_camera^)
      if nav_debug.renderer.is_initialized {
        // Render navigation debug
        mjolnir.navigation_debug_render(
          &nav_debug,
          engine,
          command_buffer,
          view_matrix,
          proj_matrix,
        )
      }
    }
  }
}

render_2d :: proc(engine: ^mjolnir.Engine, ctx: ^mu.Context) {
  using mjolnir
  if mu.window(ctx, "Particle System", {40, 360, 300, 200}, {.NO_CLOSE}) {
    rendered, max_particles := get_particle_render_stats(&engine.particle)
    mu.label(ctx, fmt.tprintf("Rendered %d", rendered))
    mu.label(ctx, fmt.tprintf("Max Particles %d", max_particles))
    efficiency := f32(rendered) / f32(max_particles) * 100.0
    mu.label(ctx, fmt.tprintf("Efficiency %.1f%%", efficiency))
  }

  if mu.window(ctx, "Shadow Debug", {990, 40, 280, 150}, {.NO_CLOSE}) {
    mu.label(ctx, "Shadow Map Information:")
    mu.label(
      ctx,
      fmt.tprintf("Shadow Map Size: %dx%d", SHADOW_MAP_SIZE, SHADOW_MAP_SIZE),
    )
    mu.label(ctx, fmt.tprintf("Max Shadow Maps: %d", MAX_SHADOW_MAPS))
    mu.text(ctx, "Check console for detailed")
    mu.text(ctx, "shadow rendering debug info")
  }

  when mjolnir.USE_GPU_CULLING {
    if mu.window(ctx, "GPU Culling", {990, 200, 280, 240}, {.NO_CLOSE}) {
      mu.label(ctx, fmt.tprintf("Max Nodes: %d", mjolnir.MAX_NODES_IN_SCENE))
      mu.label(ctx, fmt.tprintf("Max Cameras: %d", mjolnir.MAX_ACTIVE_CAMERAS))

      total_nodes := len(engine.scene.nodes.entries) - len(engine.scene.nodes.free_indices)
      mu.label(ctx, fmt.tprintf("Active Nodes: %d", total_nodes))

      // Memory usage calculation
      visibility_buffer_mb := f32(mjolnir.MAX_ACTIVE_CAMERAS * mjolnir.MAX_NODES_IN_SCENE * size_of(b32) * mjolnir.VISIBILITY_BUFFER_COUNT) / (1024 * 1024)
      node_data_mb := f32(mjolnir.MAX_NODES_IN_SCENE * size_of(mjolnir.NodeCullingData) * mjolnir.MAX_FRAMES_IN_FLIGHT) / (1024 * 1024)
      total_mb := visibility_buffer_mb + node_data_mb

      mu.label(ctx, fmt.tprintf("Memory: %.1f MB", total_mb))
      mu.label(ctx, fmt.tprintf("Visibility: %.1f MB", visibility_buffer_mb))
      mu.label(ctx, fmt.tprintf("Node Data: %.1f MB", node_data_mb))
    }
  }

  // Navigation debug UI
  if mu.window(ctx, "Navigation Debug", {40, 40, 320, 280}, {.NO_CLOSE}) {
    mu.label(ctx, "Navigation Mesh Debug")
    // Navigation mesh is available
    mu.label(ctx, fmt.tprintf("Status: %s", navmesh.max_tiles > 0 ? "Ready" : "Not loaded"))
    mu.label(ctx, fmt.tprintf("Type: Detour NavMesh"))

    mu.label(ctx, "")
    mu.label(ctx, "Controls:")
    mu.text(ctx, "F1 - Toggle nav mesh display")
    mu.text(ctx, "SPACE - Find path (start->end)")
    mu.text(ctx, "R - Random start/end positions")

    mu.label(ctx, "")
    mu.label(ctx, fmt.tprintf("Start: (%.1f, %.1f, %.1f)", start_pos.x, start_pos.y, start_pos.z))
    mu.label(ctx, fmt.tprintf("End: (%.1f, %.1f, %.1f)", end_pos.x, end_pos.y, end_pos.z))

    if len(current_path) > 0 {
      mu.label(ctx, fmt.tprintf("Current Path: %d waypoints", len(current_path)))
    } else {
      mu.label(ctx, "No active path")
    }

    debug_enabled_text := nav_debug.enabled ? "ON" : "OFF"
    mu.label(ctx, fmt.tprintf("Debug Rendering: %s", debug_enabled_text))

    mu.label(ctx, "")
    mu.label(ctx, "Obstacles: Not implemented")
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry

  // Handle camera controller switching with Tab key
  tab_pressed := glfw.GetKey(engine.window, glfw.KEY_TAB) == glfw.PRESS
  if tab_pressed && !tab_was_pressed {
    main_camera_for_sync := mjolnir.get_main_camera(engine)
    if current_controller == &orbit_controller {
      current_controller = &free_controller
      log.info("Switched to free camera")
    } else {
      current_controller = &orbit_controller
      log.info("Switched to orbit camera")
    }
    // Sync new controller with current camera state to prevent jumps
    if main_camera_for_sync != nil {
      geometry.camera_controller_sync(current_controller, main_camera_for_sync)
    }
  }
  tab_was_pressed = tab_pressed

  main_camera := mjolnir.get_main_camera(engine)
  if main_camera != nil {
    if current_controller == &orbit_controller {
      geometry.camera_controller_orbit_update(
        current_controller,
        main_camera,
        delta_time,
      )
    } else {
      geometry.camera_controller_free_update(
        current_controller,
        main_camera,
        delta_time,
      )
    }
  }

  t := time_since_app_start(engine) * 0.5
  if forcefield_node != nil {
    // forcefield_node.transform.translation = {3.0 * math.cos(t*2.0) + 2, 5.0, 3.0 * math.sin(t*2.0)}
  }
  // Move light cube
  if light := resource.get(engine.scene.nodes, light_handles[0]);
     light != nil {
    translate(
      &light.transform,
      6.0 * math.cos(t * 1.5),
      3.0,
      6.0 * math.sin(t * 1.5),
    )
  }
  if light := resource.get(engine.scene.nodes, light_handles[1]);
     light != nil {
    translate(
      &light.transform,
      5.0 * math.cos(t + math.PI),
      2.5,
      5.0 * math.sin(t + math.PI),
    )
  }
  if light := resource.get(engine.scene.nodes, light_handles[2]);
     light != nil {
    translate(
      &light.transform,
      4.0 * math.cos(t * 0.8 + math.PI * 0.5),
      1.5,
      4.0 * math.sin(t * 0.8 + math.PI * 0.5),
    )
  }
  // Move particle system to the above lights
  if light := resource.get(engine.scene.nodes, light_handles[3]);
     light != nil {
    translate(
      &light.transform,
      4.0 * math.cos(t + 1.0),
      1.5,
      4.0 * math.sin(t + 1.0),
    )
  }
  if light := resource.get(engine.scene.nodes, light_handles[4]);
     light != nil {
    translate(
      &light.transform,
      2.0 * math.cos(-t * 2.0),
      1.5,
      2.0 * math.sin(-t * 2.0),
    )
  }
  // log.infof("frame: %d", engine.frame_index)
  // log.infof("active nodes: %d", active_nodes(engine))
  if hammer := resource.get(engine.scene.nodes, hammer_handle);
     hammer != nil {
    offset_y: f32 = 0.5 * math.sin(t * 2.0)
    // Move the hammer up and down
    translate(&hammer.transform, 3, 1 + offset_y, -2)
    // Also rotate it
    rotate(&hammer.transform, 1.0 * delta_time, linalg.VECTOR3F32_Y_AXIS)
  }
}


on_key_pressed :: proc(engine: ^mjolnir.Engine, key, action, mods: int) {
  using mjolnir, geometry
  log.infof("key pressed key %d action %d mods %x", key, action, mods)
  if action == glfw.PRESS || action == glfw.REPEAT {
    switch key {
    case glfw.KEY_F5:
      log.info("F5 pressed")
    case glfw.KEY_F1:
      // Toggle navigation debug display
      mjolnir.navigation_debug_toggle(&nav_debug)
    case glfw.KEY_V:
      // Cycle through visualization modes
      mjolnir.navigation_debug_cycle_mode(&nav_debug)
      nav_debug_enabled = nav_debug.enabled
      log.infof("Navigation debug: %s", nav_debug_enabled ? "ON" : "OFF")
    case glfw.KEY_SPACE:
      // Find path between start and end positions
      find_navigation_path(start_pos, end_pos)
    case glfw.KEY_R:
      // Randomize start and end positions
      {
        // Generate random positions on the 15x15 ground plane
        ground_size: f32 = 7.0  // Stay within 15x15 bounds (-7.5 to 7.5)

        // Keep trying until we get valid positions not in obstacles
        for attempts in 0..<10 {
          start_pos = [3]f32{
            rand.float32_range(-ground_size, ground_size),
            0.1,
            rand.float32_range(-ground_size, ground_size),
          }
          if !position_in_obstacle(start_pos) do break
        }

        for attempts in 0..<10 {
          end_pos = [3]f32{
            rand.float32_range(-ground_size, ground_size),
            0.1,
            rand.float32_range(-ground_size, ground_size),
          }
          if !position_in_obstacle(end_pos) do break
        }

        log.infof("New positions - Start: [%.1f, %.1f, %.1f], End: [%.1f, %.1f, %.1f]",
          start_pos.x, start_pos.y, start_pos.z,
          end_pos.x, end_pos.y, end_pos.z)

        // Find new path
        find_navigation_path(start_pos, end_pos)
      }
    }
  }
}
