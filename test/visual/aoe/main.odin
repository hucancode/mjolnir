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
sphere_handle: resources.Handle
sphere_position: [3]f32
orbit_angle: f32 = 0.0
orbit_radius: f32 = 10.0
aoe_system: world.AOEOctree
aoe_effect_radius: f32 = 10.0

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
  log.info("AOE Test: Setup function called!")

  set_visibility_stats(engine, false)
  set_debug_ui_enabled(engine, false)

  plain_material_handle, plain_material_ok := create_material(engine)
  cube_geom := make_cube()
  cube_mesh_handle, cube_mesh_ok := create_mesh(engine, cube_geom)
  sphere_mesh_handle, sphere_mesh_ok := create_mesh(engine, make_sphere())

  cube_handles = make([dynamic]resources.Handle, 0)

  log.info("Spawning grid of cubes")
  space: f32 = 1.0
  size: f32 = 0.3
  nx, ny, nz := 50, 1, 50
  mat_handle, mat_ok := create_material(
    engine,
    metallic_value = 0.5,
    roughness_value = 0.8,
  )

  world.aoe_init(&aoe_system, geometry.Aabb{
    min = {-100, -100, -100},
    max = {100, 100, 100},
  })

  if cube_mesh_ok && mat_ok {
    for x in 0 ..< nx {
      for y in 0 ..< ny {
        for z in 0 ..< nz {
          world_x := (f32(x) - f32(nx) * 0.5) * space
          world_y := (f32(y) - f32(ny) * 0.5) * space + 0.5
          world_z := (f32(z) - f32(nz) * 0.5) * space

          node_handle, node, node_ok := spawn(
            engine,
            world.MeshAttachment {
              handle = cube_mesh_handle,
              material = mat_handle,
              cast_shadow = false,
            },
          )
          if !node_ok do continue

          translate(engine, node_handle, world_x, world_y, world_z)
          scale(engine, node_handle, size)

          append(&cube_handles, node_handle)
          position := [3]f32{world_x, world_y, world_z}
          world.aoe_insert(&aoe_system, node_handle, position)
        }
      }
    }
  }

  if sphere_mesh_ok && plain_material_ok {
    sphere_mat, sphere_mat_ok := create_material(
      engine,
      emissive_value = 5.0,
    )
    if sphere_mat_ok {
      sphere_position = {0, 1, 0}
      handle, sphere_node, sphere_ok := spawn(
        engine,
        world.MeshAttachment {
          handle = sphere_mesh_handle,
          material = sphere_mat,
          cast_shadow = false,
        },
      )
      if sphere_ok {
        sphere_handle = handle
        translate(sphere_node, sphere_position.x, sphere_position.y, sphere_position.z)
        scale(sphere_node, 0.5)
      }
    }
  }

  if main_camera := get_main_camera(engine); main_camera != nil {
    main_camera.position = {20, 20, 20}
  }

  log.info("AOE test setup complete")
}

update_aoe_test :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir

  t := time_since_start(engine)

  orbit_angle += delta_time * 0.5
  sphere_position.x = math.cos(orbit_angle) * orbit_radius
  sphere_position.y = 1.0
  sphere_position.z = math.sin(orbit_angle) * orbit_radius

  translate(engine, sphere_handle, sphere_position.x, sphere_position.y, sphere_position.z)

  affected_nodes := make([dynamic]resources.Handle, 0)
  defer delete(affected_nodes)

  world.aoe_query_sphere(&aoe_system, sphere_position, aoe_effect_radius, &affected_nodes)

  for handle in cube_handles {
    scale(engine, handle, 0.3)
  }

  shrink_scale :: 0.1
  for handle in affected_nodes {
    scale(engine, handle, shrink_scale)
  }
}
