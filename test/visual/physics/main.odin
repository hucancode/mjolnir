package main

import "../../../mjolnir"
import cont "../../../mjolnir/containers"
import "../../../mjolnir/geometry"
import "../../../mjolnir/physics"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

NX :: 33
NY :: 10
NZ :: 33
PIECE_COUNT :: NX * NY * NZ
SPHERE_RADIUS :: 3.0

physics_world: physics.World

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "Physics Visual Test - Falling Cubes")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  physics.init(&physics_world, {0, -20, 0}) // 2x earth gravity
  physics_world.enable_air_resistance = true

  ground_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  ground_mat := engine.rm.builtin_materials[resources.Color.GRAY]
  sphere_mesh := engine.rm.builtin_meshes[resources.Primitive.SPHERE]
  cylinder_mesh := engine.rm.builtin_meshes[resources.Primitive.CYLINDER]
  sphere_mat := engine.rm.builtin_materials[resources.Color.MAGENTA]
  cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  cube_mat := engine.rm.builtin_materials[resources.Color.RED]
  // Create ground
  {
    ground_node_handle := world.spawn(&engine.world, {0, -0.5, 0})
    ground_node := world.get_node(&engine.world, ground_node_handle)
    // Create static physics body (no attachment needed - it doesn't move)
    physics.create_static_body_box(
      &physics_world,
      {14.0, 0.5, 14.0},
      ground_node.transform.position,
      ground_node.transform.rotation,
    )
    // Child node with mesh
    ground_mesh_handle := mjolnir.spawn_child(
      engine,
      ground_node_handle,
      attachment = world.MeshAttachment {
        handle = ground_mesh,
        material = ground_mat,
      },
    )
    world.scale_xyz(&engine.world, ground_mesh_handle, 14.0, 0.5, 14.0)
    log.info("Ground created")
  }
  // Create sphere
  {
    sphere_node_handle := world.spawn(&engine.world, {2.5, SPHERE_RADIUS, 0})
    sphere_node := world.get_node(&engine.world, sphere_node_handle)
    physics.create_static_body_sphere(
      &physics_world,
      SPHERE_RADIUS,
      sphere_node.transform.position,
      sphere_node.transform.rotation,
    )
    sphere_mesh_handle := mjolnir.spawn_child(
      engine,
      sphere_node_handle,
      attachment = world.MeshAttachment {
        handle = sphere_mesh,
        material = sphere_mat,
        cast_shadow = true,
      },
    )
    mjolnir.scale(engine, sphere_mesh_handle, SPHERE_RADIUS)
    log.info("Sphere created")
  }
  // Create cube grid
  piece_positions: [PIECE_COUNT][3]f32
  idx := 0
  for x in 0 ..< NX {
    for y in 0 ..< NY {
      for z in 0 ..< NZ {
        if idx >= PIECE_COUNT do break
        piece_positions[idx] = {
          f32(x - NX / 2) * 3.0,
          f32(y) * 3.0 + 10.0,
          f32(z - NZ / 2) * 3.0,
        }
        idx += 1
      }
    }
  }
  box_collider := physics.create_collider_box(&physics_world, {1.0, 1.0, 1.0})
  sphere_collider := physics.create_collider_sphere(&physics_world, 1.0)
  cylinder_collider := physics.create_collider_cylinder(&physics_world, 1.0, 2.0)
  for pos, i in piece_positions {
    // Parent node with physics
    physics_node_handle := world.spawn(&engine.world, pos)
    physics_node := world.get_node(&engine.world, physics_node_handle)
    body_handle := physics.create_dynamic_body(
      &physics_world,
      physics_node.transform.position,
      physics_node.transform.rotation,
      50.0,
      false,
      cylinder_collider,
    )
    if body, ok := physics.get_dynamic_body(&physics_world, body_handle); ok {
      physics.set_cylinder_inertia(body, 1.0, 2.0)
    }
    physics_node.attachment = world.RigidBodyAttachment {
      body_handle = body_handle,
    }
    // Child node with mesh
    visual_node_handle := mjolnir.spawn_child(
      engine,
      physics_node_handle,
      attachment = world.MeshAttachment {
        handle = cylinder_mesh,
        material = cube_mat,
        cast_shadow = true,
      },
    )
  }
  log.infof("Created %d cubes", PIECE_COUNT)
  if camera := get_main_camera(engine); camera != nil {
    camera_look_at(camera, {30, 25, 30}, {0, 5, 0})
    sync_active_camera_controller(engine)
  }
  light_handle := spawn_spot_light(
    engine,
    {0.8, 0.9, 1, 1},
    50.0,
    math.PI * 0.25,
    position = {0, 20, 0},
  )
  rotate(engine, light_handle, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  log.info("Physics demo setup complete")
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  physics.step(&physics_world, delta_time)
  world.sync_all_physics_to_world(&engine.world, &physics_world)
}
