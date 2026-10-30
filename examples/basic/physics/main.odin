// Rigid bodies of every collider shape (sphere, box, cylinder) falling and stacking.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "mjolnir/physics"
import "core:log"
import "core:math/rand"
import "mjolnir/geometry"

NX :: #config(NX, 4)
NY :: #config(NY, 3)
NZ :: #config(NZ, 5)
PIECE_COUNT :: NX * NY * NZ
SPHERE_RADIUS :: 3.0
PLANE_WIDTH :: max(10.0, NX * 0.8)
PLANE_HEIGHT :: max(10.0, NZ * 0.8)

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  phys:     physics.World,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Physics") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  if !physics.init(&app.phys) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      update = update,
      render = draw,
    },
  )
}

shutdown :: proc(app: ^App) {
  physics.shutdown(&app.phys)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  app.renderer.skybox_intensity = 0
  rand_sphere := geometry.make_sphere()
  rand_cylinder := geometry.make_cylinder()
  for &v in rand_sphere.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  for &v in rand_cylinder.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  rand_sphere_mesh := render.mesh_create(&app.renderer, rand_sphere)
  rand_cylinder_mesh := render.mesh_create(&app.renderer, rand_cylinder)
  white := app.renderer.builtin_materials[.WHITE]
  cylinder_look := render.MeshAttachment{mesh = rand_cylinder_mesh, material = white, cast_shadow = true}
  sphere_look := render.MeshAttachment{mesh = rand_sphere_mesh, material = white, cast_shadow = true}

  ground_position := [3]f32{0, -0.5, 0}
  ground_half_extents := [3]f32{PLANE_WIDTH, 0.5, PLANE_HEIGHT}
  ground := world.spawn(&app.scene, ground_position)
  physics.body_create(&app.phys, ground_position, collider = physics.BoxCollider{half_extents = ground_half_extents}, user = world.Handle(ground))
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .GRAY), parent = ground, scale = ground_half_extents)

  ball_position := [3]f32{2.5, SPHERE_RADIUS, 0}
  ball := world.spawn(&app.scene, ball_position)
  physics.body_create(&app.phys, ball_position, collider = physics.SphereCollider{radius = SPHERE_RADIUS}, user = world.Handle(ball))
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .SPHERE, .MAGENTA), parent = ball, scale = SPHERE_RADIUS)

  for x in 0 ..< NX do for y in 0 ..< NY do for z in 0 ..< NZ {
    pos := [3]f32{f32(x - NX/2) * 3.0, f32(y) * 3.0 + 10.0, f32(z - NZ/2) * 3.0}
    i := (x * NY + y) * NZ + z
    collider: physics.Collider
    look := cylinder_look
    switch i % 3 {
    case 0: collider = physics.CylinderCollider{radius = 1.0, half_height = 1.0}
    case 1: collider = physics.BoxCollider{half_extents = {1.0, 1.0, 1.0}}; look = render.primitive(&app.renderer, .CUBE, .RED)
    case 2: collider = physics.SphereCollider{radius = 1.0}; look = sphere_look
    }
    node := world.spawn(&app.scene, pos)
    physics.body_create(&app.phys, pos, mass = 50.0, collider = collider, user = world.Handle(node))
    mjolnir.spawn(&app.scene, &app.renderer, look, parent = node)
  }
  log.infof("Created %d physics objects", PIECE_COUNT)
  app.orbit = render.make_orbit({10, 15, 10}, {0, 5, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  physics.step(&app.phys, dt)
  mjolnir.sync_bodies(&app.scene, &app.phys)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
