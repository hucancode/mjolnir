package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/geometry"
import "../../mjolnir/physics"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:os"
import "vendor:glfw"

physics_world: physics.World
cube_mesh_handles: [dynamic]world.NodeHandle
cube_body_to_mesh: map[physics.TriggerHandle]world.NodeHandle
effector_sphere: world.NodeHandle
effector_position: [3]f32
orbit_angle: f32 = 0.0
orbit_radius: f32 = 15.0
effect_radius: f32 = 10.0
cube_scale: f32 = 0.3
clicked_cube: world.NodeHandle
last_mouse_button_state: bool = false

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "AOE Query")
}

setup :: proc(engine: ^mjolnir.Engine) {
  physics.init(&physics_world)
  cube_body_to_mesh = make(map[physics.TriggerHandle]world.NodeHandle)
  engine.render.visibility.stats_enabled = false
  engine.debug_ui_enabled = false
  // Use builtin meshes and materials
  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  cube_mat := world.get_builtin_material(&engine.world, .CYAN)
  // Emissive material for effector sphere
  effector_mat := world.create_material(&engine.world, emissive_value = 5.0)
  // Spawn 50x50 grid of cubes
  grid_size := 50
  spacing: f32 = 1.0
  log.infof("Spawning %dx%d grid of cubes...", grid_size, grid_size)
  for x in 0 ..< grid_size {
    for z in 0 ..< grid_size {
      world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
      world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
      // Create trigger body for cube
      body_handle := physics.create_trigger_box(
        &physics_world,
        {0.5 * cube_scale, 0.5 * cube_scale, 0.5 * cube_scale},
        position = {world_x, 0.5, world_z},
      ) or_continue
      physics_node := world.spawn(
        &engine.world,
        {world_x, 0.5, world_z},
      ) or_continue
      mesh_handle := world.spawn_child(
        &engine.world,
        physics_node,
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = cube_mat,
          cast_shadow = false,
        },
      ) or_continue
      world.scale(&engine.world, mesh_handle, cube_scale)
      append(&cube_mesh_handles, mesh_handle)
      cube_body_to_mesh[body_handle] = mesh_handle
    }
  }
  // Spawn effector sphere
  effector_position = {0, 1, 0}
  effector_sphere =
    world.spawn(
      &engine.world,
      {0, 0, 0},
      attachment = world.MeshAttachment {
        handle = sphere_mesh,
        material = effector_mat,
        cast_shadow = false,
      },
    ) or_else {}
  world.translate(
    &engine.world,
    effector_sphere,
    effector_position.x,
    effector_position.y,
    effector_position.z,
  )
  world.scale(&engine.world, effector_sphere, 0.5)
  world.main_camera_look_at(
    &engine.world,
    engine.world.main_camera,
    {10, 30, 10},
    {0, 0, 0},
  )
  // Build initial BVH for all bodies
  physics.step(&physics_world, 0.0)
  world.sync_all_physics_to_world(&engine.world, &physics_world)
  log.infof("AOE test setup complete: %d cubes", len(cube_mesh_handles))
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Update physics (needed for BVH queries even with static bodies)
  physics.step(&physics_world, delta_time)
  world.sync_all_physics_to_world(&engine.world, &physics_world)
  // Handle mouse click for raycasting
  mouse_button_pressed := engine.input.mouse_buttons[glfw.MOUSE_BUTTON_LEFT]
  mouse_just_clicked := mouse_button_pressed && !last_mouse_button_state
  last_mouse_button_state = mouse_button_pressed
  mouse_click: if mouse_just_clicked {
    camera := cont.get(
      engine.world.cameras,
      engine.world.main_camera,
    )
    if camera != nil {
      // Get mouse position in window coordinates
      mouse_x_window := f32(engine.input.mouse_pos.x)
      mouse_y_window := f32(engine.input.mouse_pos.y)
      // Convert to framebuffer coordinates by scaling with content scale
      dpi_scale := mjolnir.get_window_dpi(engine.window)
      mouse_x := mouse_x_window * dpi_scale
      mouse_y := mouse_y_window * dpi_scale
      // Perform raycast from camera through mouse position
      ray_origin, ray_dir := world.camera_viewport_to_world_ray(
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
      hit := physics.raycast_trigger(&physics_world, ray)
      if !hit.hit {
        clicked_cube = {}
        break mouse_click
      }
      clicked_cube = {}
      #partial switch body_handle in hit.body_handle {
      case physics.TriggerHandle:
        if mesh_handle, ok := cube_body_to_mesh[body_handle]; ok {
          clicked_cube = mesh_handle
        }
      }
    }
  }
  // Move effector sphere in circular orbit
  orbit_angle += delta_time * 0.5
  effector_position.x = math.cos(orbit_angle) * orbit_radius
  effector_position.y = 1.0
  effector_position.z = math.sin(orbit_angle) * orbit_radius
  world.translate(
    &engine.world,
    effector_sphere,
    effector_position.x,
    effector_position.y,
    effector_position.z,
  )
  // Reset all cubes to normal scale
  for handle in cube_mesh_handles {
    world.scale(&engine.world, handle, cube_scale)
  }
  // Query for cubes within effect radius using physics
  affected: [dynamic]physics.TriggerHandle
  defer delete(affected)
  physics.query_triggers_in_sphere(
    &physics_world,
    effector_position,
    effect_radius,
    &affected,
  )
  // Shrink affected cubes
  for body_handle in affected {
    if mesh_handle, ok := cube_body_to_mesh[body_handle]; ok {
      world.scale(&engine.world, mesh_handle, 0.1)
    }
  }
  // Scale the clicked cube 3x
  world.scale(&engine.world, clicked_cube, cube_scale * 3.0)
}
