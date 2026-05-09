package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import "../../mjolnir/physics"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

NX :: #config(NX, 4)
NY :: #config(NY, 3)
NZ :: #config(NZ, 5)
PIECE_COUNT :: NX * NY * NZ
SPHERE_RADIUS :: 3.0
PLANE_WIDTH :: max(10.0, NX * 0.8)
PLANE_HEIGHT :: max(10.0, NZ * 0.8)

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  mjolnir.run(engine, 800, 600, "Physics")
}

setup :: proc(engine: ^mjolnir.Engine) {
  // engine.physics.gravity = {0, -20, 0} // 2x earth gravity
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
    ground_node := world.node(&engine.world, ground_node_handle)
    physics.create_static_body(
      &engine.physics,
      ground_node.transform.position,
      ground_node.transform.rotation,
      physics.BoxCollider{half_extents = {PLANE_WIDTH, 0.5, PLANE_HEIGHT}},
    )
    ground_mesh_handle :=
      world.spawn_child(
        &engine.world,
        ground_node_handle,
        attachment = world.MeshAttachment {
          handle = ground_mesh,
          material = ground_mat,
        },
      ) or_else {}
    world.scale_xyz(&engine.world, ground_mesh_handle, PLANE_WIDTH, 0.5, PLANE_HEIGHT)
    log.info("Ground created")
  }
  // Create sphere
  {
    sphere_node_handle :=
      world.spawn(&engine.world, {2.5, SPHERE_RADIUS, 0}) or_else {}
    sphere_node := world.node(&engine.world, sphere_node_handle)
    physics.create_static_body(
      &engine.physics,
      sphere_node.transform.position,
      sphere_node.transform.rotation,
      physics.SphereCollider{radius = SPHERE_RADIUS},
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
  piece_positions: [][3]f32 = make([][3]f32, PIECE_COUNT)
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
    physics_node_handle := world.spawn(&engine.world, pos) or_else {}
    physics_node := world.node(&engine.world, physics_node_handle)

    shape_type := i % 3
    body_handle: physics.DynamicRigidBodyHandle
    mesh_handle: world.MeshHandle
    mat_handle: world.MaterialHandle

    switch shape_type {
    case 0:
      body_handle = physics.create_dynamic_body(
        &engine.physics,
        physics_node.transform.position,
        physics_node.transform.rotation,
        50.0,
        physics.CylinderCollider{radius = 1.0, height = 2.0},
      )
      if body, ok := physics.get_dynamic_body(&engine.physics, body_handle);
         ok {
        physics.set_cylinder_inertia(body, 1.0, 2.0)
      }
      mesh_handle = rand_cylinder_mesh
      mat_handle = rand_mat
    case 1:
      body_handle = physics.create_dynamic_body(
        &engine.physics,
        physics_node.transform.position,
        physics_node.transform.rotation,
        50.0,
        physics.BoxCollider{half_extents = {1.0, 1.0, 1.0}},
      )
      if body, ok := physics.get_dynamic_body(&engine.physics, body_handle);
         ok {
        physics.set_box_inertia(body, {1.0, 1.0, 1.0})
      }
      mesh_handle = cube_mesh
      mat_handle = cube_mat
    case 2:
      body_handle = physics.create_dynamic_body(
        &engine.physics,
        physics_node.transform.position,
        physics_node.transform.rotation,
        50.0,
        physics.SphereCollider{radius = 1.0},
      )
      if body, ok := physics.get_dynamic_body(&engine.physics, body_handle);
         ok {
        physics.set_sphere_inertia(body, 1.0)
      }
      mesh_handle = rand_sphere_mesh
      mat_handle = rand_mat
    }

    physics_node.attachment = world.RigidBodyAttachment {
      body_handle = body_handle,
    }
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
  world.rotate(
    &engine.world,
    light_handle,
    math.PI * 0.5,
    linalg.VECTOR3F32_X_AXIS,
  )
}
