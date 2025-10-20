package main

import "core:log"
import "core:os"
import "core:math"
import "core:math/linalg"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"

cube_handles: [dynamic]resources.Handle
effector_sphere: resources.Handle
effector_position: [3]f32
orbit_angle: f32 = 0.0
orbit_radius: f32 = 15.0
effect_radius: f32 = 10.0

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
  set_debug_ui_enabled(engine, false)

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
    main_camera.position = {30, 30, 30}
    resources.camera_look_at(main_camera, main_camera.position, {0, 0, 0})
  }

  log.infof("AOE test setup complete: %d cubes", len(cube_handles))
}

update_aoe_test :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir

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

  world.aoe_query_sphere(&engine.world.aoe, effector_position, effect_radius, &affected)

  // Shrink affected cubes
  for handle in affected {
    scale(engine, handle, 0.1)
  }
}
