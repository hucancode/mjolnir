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

NX :: 8
NY :: 5
NZ :: 8
CUBE_COUNT :: NX*NY*NZ
SPHERE_RADIUS :: 3.0

physics_world: physics.PhysicsWorld
cube_handles: [CUBE_COUNT]resources.Handle
sphere_handle: resources.Handle
ground_handle: resources.Handle
cube_bodies: [CUBE_COUNT]resources.Handle
sphere_body: resources.Handle
ground_body: resources.Handle

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
  physics.init(&physics_world)
  // Create ground plane (large thin box)
  ground_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  ground_mat := engine.rm.builtin_materials[resources.Color.GRAY]
  ground_handle = spawn_at(
    engine,
    [3]f32{0, -0.5, 0},
    world.MeshAttachment{handle = ground_mesh, material = ground_mat},
  )
  world.scale_xyz(&engine.world, ground_handle, 40.0, 0.5, 40.0)
  ground_node, ground_node_ok := cont.get(engine.world.nodes, ground_handle)
  if ground_node_ok {
    body_handle, body, ok := physics.create_body(
      &physics_world,
      ground_handle,
      0.0,
      true, // static
    )
    if ok {
      ground_body = body_handle
      collider := physics.collider_create_box([3]f32{40.0, 0.5, 40.0})
      physics.add_collider(&physics_world, body_handle, collider)
      log.info("Ground body created")
    }
  }
  sphere_mesh := engine.rm.builtin_meshes[resources.Primitive.SPHERE]
  sphere_mat := engine.rm.builtin_materials[resources.Color.MAGENTA]
  sphere_handle = spawn_at(
    engine,
    [3]f32{0, SPHERE_RADIUS, 0},
    world.MeshAttachment {
      handle = sphere_mesh,
      material = sphere_mat,
      cast_shadow = true,
    },
  )
  mjolnir.scale(engine, sphere_handle, SPHERE_RADIUS)
  sphere_node, sphere_node_ok := cont.get(engine.world.nodes, sphere_handle)
  if sphere_node_ok {
    body_handle, body, ok := physics.create_body(
      &physics_world,
      sphere_handle,
      0.0,
      true, // static
    )
    if ok {
      sphere_body = body_handle
      collider := physics.collider_create_sphere(SPHERE_RADIUS)
      physics.add_collider(&physics_world, body_handle, collider)
      physics.rigid_body_set_sphere_inertia(body, SPHERE_RADIUS)
      log.info("Sphere body created with low friction (slippery surface)")
    }
  }
  cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  cube_mat := engine.rm.builtin_materials[resources.Color.RED]
  cube_positions: [CUBE_COUNT][3]f32
  idx := 0
  for x in 0 ..< NX {
    for y in 0 ..< NY {
      for z in 0 ..< NZ {
        if idx >= CUBE_COUNT do break
        cube_positions[idx] = {
          f32(x - NX/2) * 3.0,
          f32(y) * 3.0 + 10.0,
          f32(z - NZ/2) * 3.0,
        }
        idx += 1
      }
    }
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
    cube_node, cube_node_ok := cont.get(engine.world.nodes, cube_handles[i])
    if cube_node_ok {
      body_handle, body, ok := physics.create_body(
        &physics_world,
        cube_handles[i],
        1.0, // mass
        false, // dynamic
      )
      if ok {
        cube_bodies[i] = body_handle
        collider := physics.collider_create_box([3]f32{1.0, 1.0, 1.0})
        physics.add_collider(&physics_world, body_handle, collider)
        physics.rigid_body_set_box_inertia(body, [3]f32{1.0, 1.0, 1.0})
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
  if camera := get_main_camera(engine); camera != nil {
    resources.camera_look_at(camera, {30, 25, 30}, {0, 5, 0})
    world.camera_controller_sync(&engine.orbit_controller, camera)
  }
  spot_light_handle := spawn_spot_light(engine, {0.8, 0.9, 1, 1}, 50.0, math.PI * 0.3, position = {0, 20, 0})
  rotate(engine, spot_light_handle, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  log.info("Physics demo setup complete")
}

frame_count: int = 0

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  physics.step(&physics_world, &engine.world, delta_time)
  // Debug: Check cube positions every 60 frames (once per second)
  frame_count += 1
  if frame_count % 60 == 0 {
    for i in 0 ..< CUBE_COUNT {
      if cube_node, ok := cont.get(engine.world.nodes, cube_handles[i]); ok {
        if cube_body, ok2 := cont.get(physics_world.bodies, cube_bodies[i]);
           ok2 {
          y_pos := cube_node.transform.position.y
          vel_y := cube_body.velocity.y
          // Warn if cube is below ground level (should be at y >= 0.5 for center)
          if y_pos < 0.0 {
            log.warnf("Cube %d SUNK: y=%.3f, vy=%.3f", i, y_pos, vel_y)
          }
        }
      }
    }
    log.infof(
      "Frame %d: %d contacts",
      frame_count,
      len(physics_world.contacts),
    )
  }
}
