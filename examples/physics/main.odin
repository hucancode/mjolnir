package main

import "../../mjolnir"
import "../../mjolnir/world"
import "../../mjolnir/geometry"
import "../../mjolnir/physics"
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
  mjolnir.run_app({title = "Physics", setup = setup})
}

setup :: proc(engine: ^mjolnir.Engine) {
  ground_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  sphere_mat := world.get_builtin_material(&engine.world, .MAGENTA)
  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  cube_mat := world.get_builtin_material(&engine.world, .RED)
  rand_sphere_mesh := world.create_mesh(&engine.world, geometry.make_sphere(random_colors = true))
  rand_cylinder_mesh := world.create_mesh(&engine.world, geometry.make_cylinder(random_colors = true))
  rand_mat := world.get_builtin_material(&engine.world, .WHITE)

  mjolnir.spawn_static(engine, {0, -0.5, 0}, physics.BoxCollider{half_extents = {PLANE_WIDTH, 0.5, PLANE_HEIGHT}},
    ground_mesh, ground_mat)
  mjolnir.spawn_static(engine, {2.5, SPHERE_RADIUS, 0}, physics.SphereCollider{radius = SPHERE_RADIUS},
    sphere_mesh, sphere_mat)

  for x in 0 ..< NX do for y in 0 ..< NY do for z in 0 ..< NZ {
    pos := [3]f32{f32(x - NX/2) * 3.0, f32(y) * 3.0 + 10.0, f32(z - NZ/2) * 3.0}
    i := (x * NY + y) * NZ + z
    switch i % 3 {
    case 0: mjolnir.spawn_dynamic(engine, pos, 50.0, physics.CylinderCollider{radius = 1.0, height = 2.0}, rand_cylinder_mesh, rand_mat)
    case 1: mjolnir.spawn_dynamic(engine, pos, 50.0, physics.BoxCollider{half_extents = {1.0, 1.0, 1.0}}, cube_mesh, cube_mat)
    case 2: mjolnir.spawn_dynamic(engine, pos, 50.0, physics.SphereCollider{radius = 1.0}, rand_sphere_mesh, rand_mat)
    }
  }
  log.infof("Created %d physics objects", PIECE_COUNT)
  world.main_camera_look_at(&engine.world, {30, 25, 30}, {0, 5, 0})
  light := world.spawn_light_spot(&engine.world, {0, 20, 0}, {0.8, 0.9, 1, 1}, 25.0, math.PI * 0.25)
  world.rotate(&engine.world, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
}
