package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/geometry"
import "../../mjolnir/physics"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

NX :: #config(NX, 3)
NY :: #config(NY, 2)
NZ :: #config(NZ, 3)
PIECE_COUNT :: NX * NY * NZ
SPHERE_RADIUS :: 3.0

physics_world: physics.World

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "Physics Stress Test")
}

setup :: proc(engine: ^mjolnir.Engine) {
  physics.init(&physics_world, {0, -20, 0}) // 2x earth gravity
  ground_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  sphere_mat := world.get_builtin_material(&engine.world, .MAGENTA)
  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  cube_mat := world.get_builtin_material(&engine.world, .RED)
  rand_sphere_mesh, _, _ := world.create_mesh(
    &engine.world,
    geometry.make_sphere(random_colors = true),
  )
  rand_cylinder_mesh, _, _ := world.create_mesh(
    &engine.world,
    geometry.make_cylinder(random_colors = true),
  )
  rand_mat := world.get_builtin_material(&engine.world, .WHITE)
  // Create ground
  {
    ground_node_handle := world.spawn(&engine.world, {0, -0.5, 0}) or_else {}
    ground_node := world.get_node(&engine.world, ground_node_handle)
    // Create static physics body (no attachment needed - it doesn't move)
    physics.create_static_body_box(
      &physics_world,
      {14.0, 0.5, 14.0},
      ground_node.transform.position,
      ground_node.transform.rotation,
    )
    // Child node with mesh
    ground_mesh_handle :=
      world.spawn_child(
        &engine.world,
        ground_node_handle,
        attachment = world.MeshAttachment {
          handle = ground_mesh,
          material = ground_mat,
        },
      ) or_else {}
    world.scale_xyz(&engine.world, ground_mesh_handle, 14.0, 0.5, 14.0)
    log.info("Ground created")
  }
  // Create sphere
  {
    sphere_node_handle :=
      world.spawn(&engine.world, {2.5, SPHERE_RADIUS, 0}) or_else {}
    sphere_node := world.get_node(&engine.world, sphere_node_handle)
    physics.create_static_body_sphere(
      &physics_world,
      SPHERE_RADIUS,
      sphere_node.transform.position,
      sphere_node.transform.rotation,
    )
    sphere_mesh_handle :=
      world.spawn_child(
        &engine.world,
        sphere_node_handle,
        attachment = world.MeshAttachment {
          handle = sphere_mesh,
          material = sphere_mat,
          cast_shadow = true,
        },
      ) or_else {}
    world.scale(&engine.world, sphere_mesh_handle, SPHERE_RADIUS)
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
  for pos, i in piece_positions {
    // Parent node with physics
    physics_node_handle := world.spawn(&engine.world, pos) or_else {}
    physics_node := world.get_node(&engine.world, physics_node_handle)

    // Alternate between cylinder (0), cube (1), and sphere (2)
    shape_type := i % 3
    body_handle: physics.DynamicRigidBodyHandle
    mesh_handle: world.MeshHandle
    mat_handle: world.MaterialHandle

    switch shape_type {
    case 0:
      // Cylinder
      body_handle = physics.create_dynamic_body_cylinder(
        &physics_world,
        1.0,
        2.0,
        physics_node.transform.position,
        physics_node.transform.rotation,
        50.0,
      )
      if body, ok := physics.get_dynamic_body(&physics_world, body_handle);
         ok {
        physics.set_cylinder_inertia(body, 1.0, 2.0)
      }
      mesh_handle = rand_cylinder_mesh
      mat_handle = rand_mat
    case 1:
      // Cube
      body_handle = physics.create_dynamic_body_box(
        &physics_world,
        {1.0, 1.0, 1.0},
        physics_node.transform.position,
        physics_node.transform.rotation,
        50.0,
      )
      if body, ok := physics.get_dynamic_body(&physics_world, body_handle);
         ok {
        physics.set_box_inertia(body, {1.0, 1.0, 1.0})
      }
      mesh_handle = cube_mesh
      mat_handle = cube_mat
    case 2:
      // Sphere
      body_handle = physics.create_dynamic_body_sphere(
        &physics_world,
        1.0,
        physics_node.transform.position,
        physics_node.transform.rotation,
        50.0,
      )
      if body, ok := physics.get_dynamic_body(&physics_world, body_handle);
         ok {
        physics.set_sphere_inertia(body, 1.0)
      }
      mesh_handle = rand_sphere_mesh
      mat_handle = rand_mat
    }

    physics_node.attachment = world.RigidBodyAttachment {
      body_handle = body_handle,
    }
    // Child node with mesh
    visual_node_handle :=
      world.spawn_child(
        &engine.world,
        physics_node_handle,
        attachment = world.MeshAttachment {
          handle = mesh_handle,
          material = mat_handle,
          cast_shadow = true,
        },
      ) or_else {}
  }
  log.infof("Created %d physics objects", PIECE_COUNT)
  world.main_camera_look_at(
    &engine.world,
    transmute(world.CameraHandle)engine.render.main_camera,
    {30, 25, 30},
    {0, 5, 0},
  )
  light_handle :=
    world.spawn(
      &engine.world,
      {0, 20, 0},
      world.create_spot_light_attachment(
        {0.8, 0.9, 1, 1},
        25.0,
        math.PI * 0.25,
        true,
      ),
    ) or_else {}
  world.register_active_light(&engine.world, light_handle)
  world.rotate(
    &engine.world,
    light_handle,
    math.PI * 0.5,
    linalg.VECTOR3F32_X_AXIS,
  )
  log.info("Physics demo setup complete")
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  physics.step(&physics_world, delta_time)
  world.sync_all_physics_to_world(&engine.world, &physics_world)
}
