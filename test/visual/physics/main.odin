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

CUBE_COUNT :: 15

physics_world: physics.PhysicsWorld
cube_handles:  [CUBE_COUNT]resources.Handle
sphere_handle: resources.Handle
ground_handle: resources.Handle
cube_bodies:   [CUBE_COUNT]resources.Handle
sphere_body:   resources.Handle
ground_body:   resources.Handle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "Physics Visual Test - Falling Cubes")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir, geometry
  log.info("Setting up physics demo")

  // Initialize physics world
  physics.init(&physics_world)
  // Create ground plane (large thin box)
  ground_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  ground_mat := engine.rm.builtin_materials[resources.Color.GRAY]
  ground_handle = spawn_at(
    engine,
    [3]f32{0, -0.5, 0},
    world.MeshAttachment{handle = ground_mesh, material = ground_mat},
  )
  world.scale_xyz(&engine.world, ground_handle, 15.0, 0.5, 15.0)
  // Create static rigid body for ground
  ground_node, ground_node_ok := cont.get(
    engine.world.nodes,
    ground_handle,
  )
  if ground_node_ok {
    body_handle, body, ok := physics.create_body(
      &physics_world,
      ground_handle,
      0.0,
      true, // static
    )
    if ok {
      ground_body = body_handle
      collider := physics.collider_create_box([3]f32{15.0, 0.5, 15.0})
      physics.add_collider(&physics_world, body_handle, collider)
      log.info("Ground body created")
    }
  }

  // Create static sphere in the center
  sphere_mesh := engine.rm.builtin_meshes[resources.Primitive.SPHERE]
  sphere_mat := engine.rm.builtin_materials[resources.Color.MAGENTA]
  sphere_handle = spawn_at(
    engine,
    [3]f32{0, 1.5, 0},
    world.MeshAttachment {
      handle = sphere_mesh,
      material = sphere_mat,
      cast_shadow = true,
    },
  )
  mjolnir.scale(engine, sphere_handle, 1.5)
  // Create static rigid body for sphere
  sphere_node, sphere_node_ok := cont.get(
    engine.world.nodes,
    sphere_handle,
  )
  if sphere_node_ok {
    body_handle, body, ok := physics.create_body(
      &physics_world,
      sphere_handle,
      0.0,
      true, // static
    )
    if ok {
      sphere_body = body_handle
      collider := physics.collider_create_sphere(1.5)
      physics.add_collider(&physics_world, body_handle, collider)
      physics.rigid_body_set_sphere_inertia(body, 1.5)
      log.info("Sphere body created")
    }
  }

  // Create cubes from above
  cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  cube_mat := engine.rm.builtin_materials[resources.Color.RED]

  cube_positions := [CUBE_COUNT][3]f32 {
    // First ring around sphere
    {-3, 8, -2},
    {-1, 9, 1},
    {1, 10, -1},
    {3, 11, 2},
    {0, 12, 0},
    // Second ring, slightly offset
    {-2, 13, 0},
    {2, 14, 1},
    {0, 15, -2},
    {-1, 16, -1},
    {1, 17, 2},
    // Third ring, higher up
    {-3, 18, 1},
    {3, 19, -1},
    {0, 20, 3},
    {-2, 21, -3},
    {2, 22, 0},
  }

  for pos, i in cube_positions {
    cube_handles[i] = spawn_at(
      engine,
      pos,
      world.MeshAttachment {
        handle = cube_mesh,
        material = cube_mat,
        cast_shadow = true,
      },
    )
    // Create dynamic rigid body for each cube
    cube_node, cube_node_ok := cont.get(
      engine.world.nodes,
      cube_handles[i],
    )
    if cube_node_ok {
      body_handle, body, ok := physics.create_body(
        &physics_world,
        cube_handles[i],
        1.0, // mass
        false, // not static (dynamic)
      )
      if ok {
        cube_bodies[i] = body_handle
        collider := physics.collider_create_box([3]f32{0.5, 0.5, 0.5})
        physics.add_collider(&physics_world, body_handle, collider)
        physics.rigid_body_set_box_inertia(body, [3]f32{0.5, 0.5, 0.5})
        log.infof(
          "Cube %d body created at position (%.2f, %.2f, %.2f)",
          i,
          pos.x,
          pos.y,
          pos.z,
        )
      }
    }
  }

  // Position camera
  camera := get_main_camera(engine)
  if camera != nil {
    resources.camera_look_at(camera, {15, 10, 15}, {0, 3, 0})
  }

  log.info("Physics demo setup complete")
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  physics.step(&physics_world, &engine.world, delta_time)
}
