package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "../../mjolnir/render/mesh"
import "../../mjolnir/physics"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"

NX :: #config(NX, 4)
NY :: #config(NY, 3)
NZ :: #config(NZ, 5)
PIECE_COUNT :: NX * NY * NZ
SPHERE_RADIUS :: 3.0
PLANE_WIDTH :: max(10.0, NX * 0.8)
PLANE_HEIGHT :: max(10.0, NZ * 0.8)

phys: physics.World

main :: proc() {
  physics.init(&phys)
  defer physics.shutdown(&phys)
  mjolnir.run_app({title = "Physics", setup = setup, update = update})
}

setup :: proc(engine: ^mjolnir.Engine) {
  ground_mesh := engine.render.builtin_meshes[.CUBE]
  ground_mat := engine.render.builtin_materials[.GRAY]
  sphere_mesh := engine.render.builtin_meshes[.SPHERE]
  sphere_mat := engine.render.builtin_materials[.MAGENTA]
  cube_mesh := engine.render.builtin_meshes[.CUBE]
  cube_mat := engine.render.builtin_materials[.RED]
  rand_sphere := mesh.make_sphere()
  rand_cylinder := mesh.make_cylinder()
  for &v in rand_sphere.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  for &v in rand_cylinder.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  rand_sphere_mesh := render.create_mesh(&engine.render, rand_sphere)
  rand_cylinder_mesh := render.create_mesh(&engine.render, rand_cylinder)
  rand_mat := engine.render.builtin_materials[.WHITE]

  ground := world.spawn(&engine.world, {0, -0.5, 0})
  physics.create_static_body(&phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {PLANE_WIDTH, 0.5, PLANE_HEIGHT}}, user = world.Handle(ground))
  ground_visual := mjolnir.spawn_mesh(engine, ground_mesh, ground_mat, parent = ground)
  world.scale_xyz(&engine.world, ground_visual, PLANE_WIDTH, 0.5, PLANE_HEIGHT)
  ball := world.spawn(&engine.world, {2.5, SPHERE_RADIUS, 0})
  physics.create_static_body(&phys, {2.5, SPHERE_RADIUS, 0}, collider = physics.SphereCollider{radius = SPHERE_RADIUS}, user = world.Handle(ball))
  ball_visual := mjolnir.spawn_mesh(engine, sphere_mesh, sphere_mat, parent = ball)
  world.scale(&engine.world, ball_visual, SPHERE_RADIUS)

  for x in 0 ..< NX do for y in 0 ..< NY do for z in 0 ..< NZ {
    pos := [3]f32{f32(x - NX/2) * 3.0, f32(y) * 3.0 + 10.0, f32(z - NZ/2) * 3.0}
    i := (x * NY + y) * NZ + z
    // Unit-sized colliders match the unit builtin meshes, so visuals need no scale.
    collider: physics.Collider
    piece_mesh, piece_mat := rand_cylinder_mesh, rand_mat
    switch i % 3 {
    case 0: collider = physics.CylinderCollider{radius = 1.0, height = 2.0}
    case 1: collider = physics.BoxCollider{half_extents = {1.0, 1.0, 1.0}}; piece_mesh, piece_mat = cube_mesh, cube_mat
    case 2: collider = physics.SphereCollider{radius = 1.0}; piece_mesh = rand_sphere_mesh
    }
    node := world.spawn(&engine.world, pos)
    physics.create_dynamic_body(&phys, pos, mass = 50.0, collider = collider, user = world.Handle(node))
    mjolnir.spawn_mesh(engine, piece_mesh, piece_mat, parent = node)
  }
  log.infof("Created %d physics objects", PIECE_COUNT)
  render.main_camera_look_at(&engine.render, {30, 25, 30}, {0, 5, 0})
  light := mjolnir.spawn(engine, {0, 20, 0}, render.spot_light_attachment({0.8, 0.9, 1, 1}, 25.0, math.PI * 0.25))
  world.rotate(&engine.world, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  physics.step(&phys, dt)
  for b in physics.body_poses(&phys) do world.set_world_pose(&engine.world, world.NodeHandle(b.user), b.position, b.rotation)
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}
