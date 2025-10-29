package main

import "core:log"
import "core:os"
import "core:math"
import "core:math/linalg"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "vendor:glfw"

cube_handles: [dynamic]resources.Handle
effector_sphere: resources.Handle
effector_position: [3]f32
orbit_angle: f32 = 0.0
orbit_radius: f32 = 15.0
effect_radius: f32 = 10.0
clicked_cube: resources.Handle
last_mouse_button_state: bool = false

main :: proc() {
  context.logger = log.create_console_logger()
  args := os.args
  log.infof("Starting AOE Visual Test with %d arguments", len(args))
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_aoe_test
  engine.update_proc = update_aoe_test
  mjolnir.run(engine, 1280, 720, "Mjolnir - AOE Test")
}

setup_aoe_test :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("AOE Test: Setup")
  set_visibility_stats(engine, false)
  engine.debug_ui_enabled = false
  // Create meshes
  cube_mesh, cube_ok := create_mesh(engine, make_cube())
  sphere_mesh, sphere_ok := create_mesh(engine, make_sphere())
  // Material for cubes
  cube_mat, cube_mat_ok := create_material(
    engine,
    metallic_value = 0.5,
    roughness_value = 0.8,
  )
  // Emissive material for effector sphere
  effector_mat, effector_mat_ok := create_material(
    engine,
    emissive_value = 5.0,
  )
  if !cube_ok || !sphere_ok || !cube_mat_ok || !effector_mat_ok {
    log.error("Failed to create test resources")
    return
  }
  // Spawn 50x50 grid of cubes
  cube_handles = make([dynamic]resources.Handle, 0)
  grid_size := 50
  spacing: f32 = 1.0
  cube_scale: f32 = 0.3
  log.infof("Spawning %dx%d grid of cubes...", grid_size, grid_size)
  for x in 0 ..< grid_size {
    for z in 0 ..< grid_size {
      world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
      world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
      handle, node, ok := spawn(
        engine,
        world.MeshAttachment {
          handle = cube_mesh,
          material = cube_mat,
          cast_shadow = false,
        },
      )
      if ok {
        translate(node, world_x, 0.5, world_z)
        scale(node, cube_scale)
        append(&cube_handles, handle)
      }
    }
  }
  // Spawn effector sphere
  effector_position = {0, 1, 0}
  handle, node, ok := spawn(
    engine,
    world.MeshAttachment {
      handle = sphere_mesh,
      material = effector_mat,
      cast_shadow = false,
    },
  )
  if ok {
    effector_sphere = handle
    translate(node, effector_position.x, effector_position.y, effector_position.z)
    scale(node, 0.5)
  }
  // Position camera
  if main_camera := get_main_camera(engine); main_camera != nil {
    main_camera.position = {10, 30, 10}
    resources.camera_look_at(main_camera, main_camera.position, {0, 0, 0})
  }
  log.infof("AOE test setup complete: %d cubes", len(cube_handles))
}

update_aoe_test :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir
  // Handle mouse click for raycasting
  mouse_button_pressed := engine.input.mouse_buttons[glfw.MOUSE_BUTTON_LEFT]
  mouse_just_clicked := mouse_button_pressed && !last_mouse_button_state
  last_mouse_button_state = mouse_button_pressed
  if mouse_just_clicked {
    camera := get_main_camera(engine)
    if camera != nil {
      // Get mouse position in window coordinates
      mouse_x_window := f32(engine.input.mouse_pos.x)
      mouse_y_window := f32(engine.input.mouse_pos.y)
      // Convert to framebuffer coordinates by scaling with content scale
      dpi_scale := get_window_dpi(engine.window)
      mouse_x := mouse_x_window * dpi_scale
      mouse_y := mouse_y_window * dpi_scale
      log.infof("=== Mouse Click Debug ===")
      log.infof("Mouse window coords: (%.1f, %.1f)", mouse_x_window, mouse_y_window)
      log.infof("DPI scale: %.2f", dpi_scale)
      log.infof("Mouse framebuffer coords: (%.1f, %.1f)", mouse_x, mouse_y)
      log.infof("Swapchain extent: %v x %v", engine.swapchain.extent.width, engine.swapchain.extent.height)
      log.infof("Camera viewport: %v x %v", camera.extent.width, camera.extent.height)
      // Calculate normalized device coordinates to verify
      ndc_x := (2.0 * mouse_x) / f32(camera.extent.width) - 1.0
      ndc_y := 1.0 - (2.0 * mouse_y) / f32(camera.extent.height)
      log.infof("Calculated NDC: (%.3f, %.3f)", ndc_x, ndc_y)
      // Show what world point the ray is aiming at
      ray_origin, ray_dir := resources.camera_viewport_to_world_ray(camera, mouse_x, mouse_y)
      target_point := ray_origin + ray_dir * 25.0
      log.infof("Ray: origin=%v, direction=%v", ray_origin, ray_dir)
      log.infof("Ray target at distance 25: %v", target_point)
      // Perform raycast from camera through mouse position
      ray_config := geometry.RaycastConfig {
        max_dist  = 1000.0,
        max_tests = 0,
        accel     = .OCTREE,  // Fixed: was .BVH but we only use OCTREE now
      }
      hit := world.camera_world_raycast(
        &engine.world,
        &engine.rm,
        camera,
        mouse_x,
        mouse_y,
        {},  // No tag filter - test all nodes
        ray_config,
      )
      if hit.hit {
        clicked_cube = hit.node_handle
        if node := world.get_node(&engine.world, hit.node_handle); node != nil {
          world_pos := node.transform.world_matrix[3].xyz
          log.infof("Hit cube at position %v, distance: %.2f", world_pos, hit.t)
          // Debug: show what the ray calculation says we should hit
          expected_x := ray_origin.x + ray_dir.x * hit.t
          expected_y := ray_origin.y + ray_dir.y * hit.t
          expected_z := ray_origin.z + ray_dir.z * hit.t
          log.infof("Ray at t=%.2f should be at: [%.2f, %.2f, %.2f]", hit.t, expected_x, expected_y, expected_z)
        }
      } else {
        clicked_cube = {}  // Clear previous selection
      }
    }
  }
  // Move effector sphere in circular orbit
  orbit_angle += delta_time * 0.5
  effector_position.x = math.cos(orbit_angle) * orbit_radius
  effector_position.y = 1.0
  effector_position.z = math.sin(orbit_angle) * orbit_radius
  translate(engine, effector_sphere,
    effector_position.x, effector_position.y, effector_position.z)
  // Reset all cubes to normal scale
  for handle in cube_handles {
    scale(engine, handle, 0.3)
  }
  // Query for cubes within effect radius
  affected := make([dynamic]resources.Handle, 0)
  defer delete(affected)
  world.query_sphere(&engine.world, effector_position, effect_radius, &affected)
  // Shrink affected cubes
  for handle in affected {
    scale(engine, handle, 0.1)
  }
  // Scale the clicked cube 3x (0.3 * 3 = 0.9)
  if clicked_cube.index != 0 {
    scale(engine, clicked_cube, 0.9)
  }
}
