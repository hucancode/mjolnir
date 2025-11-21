package main

import "../../../mjolnir"
import "../../../mjolnir/geometry"
import cont "../../../mjolnir/containers"
import "../../../mjolnir/physics"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "vendor:glfw"

physics_world: physics.PhysicsWorld
cube_handles: [dynamic]resources.Handle
cube_bodies: [dynamic]resources.Handle
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
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "Mjolnir - AOE Test")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  physics.init(&physics_world)
  set_visibility_stats(engine, false)
  engine.debug_ui_enabled = false
  // Use builtin meshes and materials
  cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  sphere_mesh := engine.rm.builtin_meshes[resources.Primitive.SPHERE]
  cube_mat := engine.rm.builtin_materials[resources.Color.CYAN]
  // Emissive material for effector sphere
  effector_mat := create_material(engine, emissive_value = 5.0)
  // Spawn 50x50 grid of cubes
  grid_size := 50
  spacing: f32 = 1.0
  cube_scale: f32 = 0.3
  log.infof("Spawning %dx%d grid of cubes...", grid_size, grid_size)
  for x in 0 ..< grid_size {
    for z in 0 ..< grid_size {
      world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
      world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
      node_handle := spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = cube_mat,
          cast_shadow = false,
        },
      ) or_continue
      translate(engine, node_handle, world_x, 0.5, world_z)
      scale(engine, node_handle, cube_scale)
      append(&cube_handles, node_handle)
      // Create physics body for cube
      collider := physics.collider_create_box({0.5, 0.5, 0.5} * cube_scale)
      body_handle, body, _ := physics.create_body(
        &physics_world,
        node_handle,
        1.0,
        true, // static
      )
      physics.add_collider(&physics_world, body_handle, collider)
      append(&cube_bodies, body_handle)
    }
  }
  // Spawn effector sphere
  effector_position = {0, 1, 0}
  effector_sphere = spawn(
    engine,
    attachment = world.MeshAttachment {
      handle = sphere_mesh,
      material = effector_mat,
      cast_shadow = false,
    },
  )
  translate(
    engine,
    effector_sphere,
    effector_position.x,
    effector_position.y,
    effector_position.z,
  )
  scale(engine, effector_sphere, 0.5)
  if main_camera := get_main_camera(engine); main_camera != nil {
    main_camera.position = {10, 30, 10}
    resources.camera_look_at(main_camera, main_camera.position, {0, 0, 0})
  }
  // Build initial BVH for all bodies
  physics.step(&physics_world, &engine.world, 0.0)
  log.infof("AOE test setup complete: %d cubes", len(cube_handles))
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir
  // Update physics (needed for BVH queries even with static bodies)
  physics.step(&physics_world, &engine.world, delta_time)
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
      log.infof(
        "Mouse window coords: (%.1f, %.1f)",
        mouse_x_window,
        mouse_y_window,
      )
      log.infof("DPI scale: %.2f", dpi_scale)
      log.infof("Mouse framebuffer coords: (%.1f, %.1f)", mouse_x, mouse_y)
      log.infof(
        "Swapchain extent: %v x %v",
        engine.swapchain.extent.width,
        engine.swapchain.extent.height,
      )
      log.infof(
        "Camera viewport: %v x %v",
        camera.extent.width,
        camera.extent.height,
      )
      // Perform raycast from camera through mouse position
      ray_origin, ray_dir := resources.camera_viewport_to_world_ray(
        camera,
        mouse_x,
        mouse_y,
      )
      ray := geometry.Ray {
        origin    = ray_origin,
        direction = ray_dir,
      }
      log.infof("Ray: origin=%v, direction=%v", ray_origin, ray_dir)
      // Use physics raycast
      hit := physics.physics_raycast(&physics_world, &engine.world, ray, 1000.0)
      if hit.hit {
        body := cont.get(physics_world.bodies, hit.body_handle)
        if body != nil {
          clicked_cube = body.node_handle
          if node := world.get_node(&engine.world, body.node_handle);
             node != nil {
            world_pos := node.transform.world_matrix[3].xyz
            log.infof(
              "Hit cube at position %v, distance: %.2f",
              world_pos,
              hit.t,
            )
          }
        }
      } else {
        clicked_cube = {} // Clear previous selection
      }
    }
  }
  // Move effector sphere in circular orbit
  orbit_angle += delta_time * 0.5
  effector_position.x = math.cos(orbit_angle) * orbit_radius
  effector_position.y = 1.0
  effector_position.z = math.sin(orbit_angle) * orbit_radius
  translate(
    engine,
    effector_sphere,
    effector_position.x,
    effector_position.y,
    effector_position.z,
  )
  // Reset all cubes to normal scale
  for handle in cube_handles {
    scale(engine, handle, 0.3)
  }
  // Query for cubes within effect radius using physics
  affected: [dynamic]resources.Handle
  defer delete(affected)
  physics.physics_query_sphere(
    &physics_world,
    &engine.world,
    effector_position,
    effect_radius,
    &affected,
  )
  // Shrink affected cubes
  for body_handle in affected {
    body := cont.get(physics_world.bodies, body_handle)
    if body != nil {
      scale(engine, body.node_handle, 0.1)
    }
  }
  // Scale the clicked cube 3x (0.3 * 3 = 0.9)
  if clicked_cube.index != 0 {
    scale(engine, clicked_cube, 0.9)
  }
}
