// Rigid bodies of every collider shape (sphere, box, cylinder) falling and stacking.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
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

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  phys:     physics.World,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !physics.init(&app.phys) do return
  w := &app.window
  if !platform.init(w, 800, 600, "Physics") do return
  if !render.init(&app.renderer, "Physics", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      should_close = should_close,
      update = update,
      frame = frame,
    },
  )
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  physics.shutdown(&app.phys)
  free(app)
}

spawn_visual :: proc(app: ^App, body_node: world.NodeHandle, mesh: render.MeshHandle, material: render.MaterialHandle) -> world.NodeHandle {
  visual := world.spawn(&app.scene, parent = body_node)
  render.attach(&app.renderer, render.SlotHandle(visual.index), render.MeshAttachment{mesh = mesh, material = material, cast_shadow = true})
  return visual
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  cube_mesh := app.renderer.builtin_meshes[.CUBE]
  sphere_mesh := app.renderer.builtin_meshes[.SPHERE]
  rand_sphere := render.make_sphere()
  rand_cylinder := render.make_cylinder()
  for &v in rand_sphere.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  for &v in rand_cylinder.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  rand_sphere_mesh := render.mesh_create(&app.renderer, rand_sphere)
  rand_cylinder_mesh := render.mesh_create(&app.renderer, rand_cylinder)
  white := app.renderer.builtin_materials[.WHITE]

  ground_position := [3]f32{0, -0.5, 0}
  ground_half_extents := [3]f32{PLANE_WIDTH, 0.5, PLANE_HEIGHT}
  ground := world.spawn(&app.scene, ground_position)
  physics.body_create(&app.phys, ground_position, collider = physics.BoxCollider{half_extents = ground_half_extents}, user = world.Handle(ground))
  ground_visual := spawn_visual(app, ground, cube_mesh, app.renderer.builtin_materials[.GRAY])
  world.scale(&app.scene, ground_visual, ground_half_extents)

  ball_position := [3]f32{2.5, SPHERE_RADIUS, 0}
  ball := world.spawn(&app.scene, ball_position)
  physics.body_create(&app.phys, ball_position, collider = physics.SphereCollider{radius = SPHERE_RADIUS}, user = world.Handle(ball))
  ball_visual := spawn_visual(app, ball, sphere_mesh, app.renderer.builtin_materials[.MAGENTA])
  world.scale(&app.scene, ball_visual, SPHERE_RADIUS)

  for x in 0 ..< NX do for y in 0 ..< NY do for z in 0 ..< NZ {
    pos := [3]f32{f32(x - NX/2) * 3.0, f32(y) * 3.0 + 10.0, f32(z - NZ/2) * 3.0}
    i := (x * NY + y) * NZ + z
    collider: physics.Collider
    piece_mesh, piece_material := rand_cylinder_mesh, white
    switch i % 3 {
    case 0: collider = physics.CylinderCollider{radius = 1.0, half_height = 1.0}
    case 1: collider = physics.BoxCollider{half_extents = {1.0, 1.0, 1.0}}; piece_mesh, piece_material = cube_mesh, app.renderer.builtin_materials[.RED]
    case 2: collider = physics.SphereCollider{radius = 1.0}; piece_mesh = rand_sphere_mesh
    }
    node := world.spawn(&app.scene, pos)
    physics.body_create(&app.phys, pos, mass = 50.0, collider = collider, user = world.Handle(node))
    spawn_visual(app, node, piece_mesh, piece_material)
  }
  log.infof("Created %d physics objects", PIECE_COUNT)
  render.camera_look_at(render.main_camera(&app.renderer), {30, 25, 30}, {0, 5, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {0, 20, 0})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_spot_light({0.8, 0.9, 1}, 5000, 25.0, math.PI * 0.25)))
  world.rotate(&app.scene, light, -math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  return .READY
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  physics.step(&app.phys, dt)
  for k in physics.killed(&app.phys) do world.destroy(&app.scene, world.NodeHandle(k.user))
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
