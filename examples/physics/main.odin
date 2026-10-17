// Basic physics engine, support primitives shape (sphere, cube, cylinder, capsule).
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
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

phys: physics.World

main :: proc() {
  context.logger = log.create_console_logger()
  physics.init(&phys)
  app := new(App)
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
  physics.shutdown(&phys)
  free(app)
}

spawn_mesh :: proc(app: ^App, m: render.MeshHandle, mat: render.MaterialHandle, parent: world.NodeHandle) -> world.NodeHandle {
  n := world.spawn(&app.scene, parent = parent)
  render.attach(&app.renderer, render.SlotHandle(n.index), render.MeshAttachment{mesh = m, material = mat, cast_shadow = true})
  return n
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  ground_mesh := app.renderer.builtin_meshes[.CUBE]
  ground_mat := app.renderer.builtin_materials[.GRAY]
  sphere_mesh := app.renderer.builtin_meshes[.SPHERE]
  sphere_mat := app.renderer.builtin_materials[.MAGENTA]
  cube_mesh := app.renderer.builtin_meshes[.CUBE]
  cube_mat := app.renderer.builtin_materials[.RED]
  rand_sphere := render.make_sphere()
  rand_cylinder := render.make_cylinder()
  for &v in rand_sphere.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  for &v in rand_cylinder.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  rand_sphere_mesh := render.mesh_create(&app.renderer, rand_sphere)
  rand_cylinder_mesh := render.mesh_create(&app.renderer, rand_cylinder)
  rand_mat := app.renderer.builtin_materials[.WHITE]

  ground := world.spawn(&app.scene, {0, -0.5, 0})
  physics.body_create(&phys, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {PLANE_WIDTH, 0.5, PLANE_HEIGHT}}, user = world.Handle(ground))
  ground_visual := spawn_mesh(app, ground_mesh, ground_mat, ground)
  world.scale(&app.scene, ground_visual, PLANE_WIDTH, 0.5, PLANE_HEIGHT)
  ball := world.spawn(&app.scene, {2.5, SPHERE_RADIUS, 0})
  physics.body_create(&phys, {2.5, SPHERE_RADIUS, 0}, collider = physics.SphereCollider{radius = SPHERE_RADIUS}, user = world.Handle(ball))
  ball_visual := spawn_mesh(app, sphere_mesh, sphere_mat, ball)
  world.scale(&app.scene, ball_visual, SPHERE_RADIUS)

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
    node := world.spawn(&app.scene, pos)
    physics.body_create(&phys, pos, mass = 50.0, collider = collider, user = world.Handle(node))
    spawn_mesh(app, piece_mesh, piece_mat, node)
  }
  log.infof("Created %d physics objects", PIECE_COUNT)
  render.camera_look_at(render.main_camera(&app.renderer), {30, 25, 30}, {0, 5, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  light := world.spawn(&app.scene, {0, 20, 0})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_spot_light({0.8, 0.9, 1, 1}, 25.0, math.PI * 0.25)))
  world.rotate(&app.scene, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  return true
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  physics.step(&phys, dt)
  for k in physics.killed(&phys) do world.destroy(&app.scene, world.NodeHandle(k.user))
  world.set_world_poses(&app.scene, physics.body_poses(&phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
