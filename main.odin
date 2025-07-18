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
start_pos: [3]f32 = {-9.5, 0.1, 9.5}   // Top-left corner of the room
end_pos: [3]f32 = {9.5, 0.1, -9.5}     // Bottom-right corner of the room
nav_debug_enabled: bool = true

// Helper function to check if a position intersects with cube grid obstacles
position_in_obstacle :: proc(pos: [3]f32) -> bool {
  x, z := pos.x, pos.z

  // Cube grid parameters (matching the scene setup)
  space: f32 = 2.1
  cube_size: f32 = 0.3
  nx, nz := 5, 5
  cube_half_size := cube_size * 0.5

  for grid_x in 1..<nx {
    for grid_z in 1..<nz {
      // Calculate cube world position (same as in setup)
      world_x := (f32(grid_x) - f32(nx) * 0.5) * space
      world_z := (f32(grid_z) - f32(nz) * 0.5) * space

      // Check if position is inside this cube (with some padding)
      if x >= world_x - cube_half_size && x <= world_x + cube_half_size &&
         z >= world_z - cube_half_size && z <= world_z + cube_half_size {
        return true
      }
    }
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
    log.info("spawning debug obstacles at specific positions")
    
    // Define the same obstacle positions as in navmesh generation
    debug_obstacles := [][3]f32{
      {0, 0.5, 0},      // Exact center
      {5, 0.5, 5},      // Northeast
      {-5, 0.5, -5},    // Southwest
      {10, 0.5, 0},     // East edge
      {0, 0.5, -10},    // South edge
      // Double the obstacles - add 5 more
      {-10, 0.5, 0},    // West edge
      {0, 0.5, 10},     // North edge
      {-8, 0.5, -8},    // Southwest corner area
      {8, 0.5, 8},      // Northeast corner area
      {-3, 0.5, 7},     // Northwest area
    }
    
    obstacle_size := f32(0.8)  // Visual obstacle size (matches actual objects)
    
    for obstacle_pos, idx in debug_obstacles {
      world_x := obstacle_pos.x
      world_y := obstacle_pos.y  
      world_z := obstacle_pos.z
      
      // Create a different colored material for each obstacle
      mat_handle, _ := create_material(
        &engine.warehouse,
        metallic_value = 0.0,
        roughness_value = 0.8,
      ) or_continue
      
      // Spawn cube at position
      _, node := spawn(
        &engine.scene,
        MeshAttachment {
          handle = cube_mesh_handle,
          material = mat_handle,
          cast_shadow = true,
        },
      )
      
      translate(&node.transform, world_x, world_y, world_z)
      scale(&node.transform, obstacle_size)
    }
  }
  if true {
    log.info("spawning ground and walls")
    // Ground node
    size: f32 = 15.0
    _, ground_node := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
      },
    )
    scale(&ground_node.transform, size)
    // Left wall
    _, left_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
      },
    )
    translate(&left_wall.transform, x = size)
    rotate(&left_wall.transform, math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
    scale(&left_wall.transform, size)
    // Right wall
    _, right_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
      },
    )
    translate(&right_wall.transform, x = -size)
    rotate(&right_wall.transform, -math.PI * 0.5, linalg.VECTOR3F32_Z_AXIS)
    scale(&right_wall.transform, size)
    // Back wall
    _, back_wall := spawn(
      &engine.scene,
      MeshAttachment {
        handle = ground_mesh_handle,
        material = ground_mat_handle,
        cast_shadow = true,
      },
    )
    translate(&back_wall.transform, y = size, z = -size)
    rotate(&back_wall.transform, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
    scale(&back_wall.transform, size)
    // // Ceiling
    // _, ceiling := spawn(
    //   &engine.scene,
    //   MeshAttachment {
    //     handle = ground_mesh_handle,
    //     material = ground_mat_handle,
    //     cast_shadow = true,
    //   },
    // )
    // translate(&ceiling.transform, y = size)
    // rotate(&ceiling.transform, -math.PI, linalg.VECTOR3F32_X_AXIS)
    // scale(&ceiling.transform, size)
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

// Build navigation mesh from the scene geometry
build_navigation_from_scene :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry

  log.info("=== Building Navigation Mesh from Scene ===")

  vertices_list := make([dynamic][3]f32)
  indices_list := make([dynamic]u32)
  areas_list := make([dynamic]u8)
  defer delete(vertices_list)
  defer delete(indices_list)
  defer delete(areas_list)

  // Collect walkable geometry (ground planes and floors)
  ground_size: f32 = 15.0  // Matching the ground scale in setup

  // Create subdivided ground mesh for better obstacle detection
  // Recast needs smaller triangles to properly cut holes for obstacles
  grid_divisions := 20  // Subdivide ground into 20x20 grid
  cell_size := (ground_size * 2) / f32(grid_divisions)

  // Generate grid vertices
  for z in 0..=grid_divisions {
    for x in 0..=grid_divisions {
      vx := -ground_size + f32(x) * cell_size
      vz := -ground_size + f32(z) * cell_size
      append(&vertices_list, [3]f32{vx, 0, vz})
    }
  }

  // Generate grid triangles
  grid_width := grid_divisions + 1
  log.infof("Grid generation: divisions=%d, width=%d", grid_divisions, grid_width)
  for z in 0..<grid_divisions {
    for x in 0..<grid_divisions {
      // Calculate vertex indices for this cell
      v0 := u32(z * grid_width + x)
      v1 := u32(z * grid_width + x + 1)
      v2 := u32((z + 1) * grid_width + x + 1)
      v3 := u32((z + 1) * grid_width + x)
      
      // Debug problematic triangle generation
      if v0 >= 441 || v1 >= 441 || v2 >= 441 || v3 >= 441 {
        log.errorf("Grid cell (%d,%d): vertices %d,%d,%d,%d exceed grid vertex count 441", x, z, v0, v1, v2, v3)
      }

      // Add two triangles for this cell
      append(&indices_list, v0, v1, v2)
      append(&indices_list, v0, v2, v3)
      append(&areas_list, navigation.WALKABLE_AREA, navigation.WALKABLE_AREA)
    }
  }

  log.infof("Ground plane: %.0fx%.0f units with %dx%d grid",
    ground_size * 2, ground_size * 2, grid_divisions, grid_divisions)
  log.infof("Ground vertices: %d, indices: %d", len(vertices_list), len(indices_list))

  // Add obstacles from the scene (cubes, cones, spheres)
  // Create a debug-friendly obstacle layout:
  obstacle_count := 0
  
  // Define specific obstacle positions for debugging
  debug_obstacles := [][3]f32{
    {0, 0, 0},      // Exact center - should block cell (15,15)
    {5, 0, 5},      // Northeast - should block cell (20,20)
    {-5, 0, -5},    // Southwest - should block cell (10,10)
    {10, 0, 0},     // East edge - should block cell (25,15)
    {0, 0, -10},    // South edge - should block cell (15,5)
    // Double the obstacles - add 5 more
    {-10, 0, 0},    // West edge
    {0, 0, 10},     // North edge
    {-8, 0, -8},    // Southwest corner area
    {8, 0, 8},      // Northeast corner area
    {-3, 0, 7},     // Northwest area
  }
  
  navmesh_obstacle_size := f32(2.0)  // Larger obstacles in navmesh for better visualization
  box_half := navmesh_obstacle_size * 0.5
  obstacle_height := f32(2.5)
  
  for obstacle_pos in debug_obstacles {
    world_x := obstacle_pos.x
    world_y := obstacle_pos.y  
    world_z := obstacle_pos.z

    // Create a box obstacle starting from slightly below ground level
    // This ensures the obstacle intersects with the ground mesh for proper hole cutting
    ground_offset := f32(-0.05)  // Extend slightly below ground to ensure intersection
    box_verts := [][3]f32{
      // Bottom vertices below ground level
      {world_x - box_half, ground_offset, world_z - box_half},
      {world_x + box_half, ground_offset, world_z - box_half},
      {world_x + box_half, ground_offset, world_z + box_half},
      {world_x - box_half, ground_offset, world_z + box_half},
      // Top vertices
      {world_x - box_half, obstacle_height, world_z - box_half},
      {world_x + box_half, obstacle_height, world_z - box_half},
      {world_x + box_half, obstacle_height, world_z + box_half},
      {world_x - box_half, obstacle_height, world_z + box_half},
    }

    base_idx := u32(len(vertices_list))
    for v in box_verts {
      append(&vertices_list, v)
    }

    // Add all faces including bottom to block the ground beneath
    // Bottom face
    append(&indices_list, base_idx + 0, base_idx + 2, base_idx + 1)
    append(&indices_list, base_idx + 0, base_idx + 3, base_idx + 2)
    append(&areas_list, navigation.NULL_AREA, navigation.NULL_AREA)

    // Top face - mark as obstacle
    append(&indices_list, base_idx + 4, base_idx + 5, base_idx + 6)
    append(&indices_list, base_idx + 4, base_idx + 6, base_idx + 7)
    append(&areas_list, navigation.NULL_AREA, navigation.NULL_AREA)

    // Side faces - all non-walkable
    // All sides - mark as obstacles
    // Front
    append(&indices_list, base_idx + 0, base_idx + 1, base_idx + 5)
    append(&indices_list, base_idx + 0, base_idx + 5, base_idx + 4)
    append(&areas_list, navigation.NULL_AREA, navigation.NULL_AREA)

    // Right
    append(&indices_list, base_idx + 1, base_idx + 2, base_idx + 6)
    append(&indices_list, base_idx + 1, base_idx + 6, base_idx + 5)
    append(&areas_list, navigation.NULL_AREA, navigation.NULL_AREA)

    // Back
    append(&indices_list, base_idx + 2, base_idx + 3, base_idx + 7)
    append(&indices_list, base_idx + 2, base_idx + 7, base_idx + 6)
    append(&areas_list, navigation.NULL_AREA, navigation.NULL_AREA)

    // Left
    append(&indices_list, base_idx + 3, base_idx + 0, base_idx + 4)
    append(&indices_list, base_idx + 3, base_idx + 4, base_idx + 7)
    append(&areas_list, navigation.NULL_AREA, navigation.NULL_AREA)

    obstacle_count += 1
  }
  
  log.infof("Added %d obstacles to navigation mesh", obstacle_count)
  log.infof("Final navigation geometry: %d vertices, %d indices (%d triangles)", 
    len(vertices_list), len(indices_list), len(indices_list)/3)

  // Convert to arrays for navigation system
  vertices := vertices_list[:]
  indices := indices_list[:]
  
  // Debug: Check first few indices before passing to navigation
  log.debugf("Input indices [0:15]: %v", indices[0:min(15, len(indices))])
  areas := areas_list[:]

  // Configure navigation mesh generation
  config := navigation.Config{
    cs = 0.2,                     // Cell size - smaller cells for better obstacle representation
    ch = 0.2,                     // Cell height
    walkable_slope_angle = 45,     // Max slope
    walkable_height = 3,          // Agent height (0.6m / 0.2m = 3 cells)
    walkable_climb = 2,           // Max climb (0.4m / 0.2m = 2 cells)
    walkable_radius = 1,          // Agent radius (0.2m / 0.2m = 1 cell)
    max_edge_len = 60,            // Max edge length (adjusted for smaller cells)
    max_simplification_error = 0.8,  // Lower error for smoother boundaries
    min_region_area = 8,          // Min region size (remove tiny regions)
    merge_region_area = 40,       // Merge region size (create cleaner regions)
    max_verts_per_poly = 6,       // Max vertices per polygon
    detail_sample_dist = 6,
    detail_sample_max_error = 1,
    tile_size = 0,                // Single tile for now
    border_size = 0,
  }

  // Create navigation builder and build mesh
  navmesh_builder = navigation.builder_init(config)
  defer navigation.builder_destroy(&navmesh_builder)

  // Create input for navigation building
  nav_input := navigation.Input{
    vertices = vertices,
    indices = indices,
    areas = areas,
  }

  // Build the mesh
  ok: bool
  log.info("Calling navigation.build...")
  navmesh, ok = navigation.build(&navmesh_builder, &nav_input)
  log.infof("navigation.build returned: ok=%v", ok)

  if !ok {
    log.error("Failed to build navigation mesh from scene!")
    return
  }

  log.info("Navigation mesh built successfully from scene geometry")
  log.infof("NavMesh: tiles=%p, max_tiles=%d", navmesh.tiles, navmesh.max_tiles)

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
        // Generate random positions on the ground plane
        ground_size: f32 = 14.0  // Slightly smaller than actual to stay on mesh

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
