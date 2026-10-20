// Physics engine via vendor:box2d.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import b2 "vendor:box2d"

NX :: #config(NX, 8)
NY :: #config(NY, 6)
PIECE_COUNT :: NX * NY
PIECE_MASS :: 50.0
PIECE_BOX_DENSITY :: PIECE_MASS / (2.0 * 2.0)
PIECE_CIRCLE_DENSITY :: PIECE_MASS / math.PI
SPHERE_RADIUS :: 3.0
SPHERE_X :: 2.5
PLANE_WIDTH :: max(10.0, NX * 0.8)
PLANE_HEIGHT :: 5.0
KILL_Y :: -50.0
BOX2D_SUBSTEPS :: 4

Piece :: struct {
  body: b2.BodyId,
  node: world.NodeHandle,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  phys:     b2.WorldId,
  pieces:   [dynamic]Piece,
  orbit:    render.Orbit,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  world_def := b2.DefaultWorldDef()
  world_def.gravity = {0, -9.81}
  app.phys = b2.CreateWorld(world_def)
  w := &app.window
  if !platform.init(w, 800, 600, "Physics (Box2D)") do return
  if !render.init(&app.renderer, "Physics (Box2D)", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  delete(app.pieces)
  b2.DestroyWorld(app.phys)
  free(app)
}

spawn_visual :: proc(app: ^App, body_node: world.NodeHandle, look: render.MeshAttachment) -> world.NodeHandle {
  visual := world.spawn(&app.scene, parent = body_node)
  render.attach(&app.renderer, render.SlotHandle(visual.index), look)
  return visual
}

shape_def :: proc(density: f32) -> b2.ShapeDef {
  def := b2.DefaultShapeDef()
  def.density = density
  def.material.friction = 0.8
  def.material.restitution = 0.2
  return def
}

body_create :: proc(app: ^App, type: b2.BodyType, position: [2]f32) -> b2.BodyId {
  def := b2.DefaultBodyDef()
  def.type = type
  def.position = position
  return b2.CreateBody(app.phys, def)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  app.renderer.skybox_intensity = 0
  rand_sphere := render.make_sphere()
  rand_cylinder := render.make_cylinder()
  for &v in rand_sphere.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  for &v in rand_cylinder.vertices do v.color = {rand.float32(), rand.float32(), rand.float32(), 1}
  rand_sphere_mesh := render.mesh_create(&app.renderer, rand_sphere)
  rand_cylinder_mesh := render.mesh_create(&app.renderer, rand_cylinder)
  white := app.renderer.builtin_materials[.WHITE]
  cylinder_look := render.MeshAttachment{mesh = rand_cylinder_mesh, material = white, cast_shadow = true}
  sphere_look := render.MeshAttachment{mesh = rand_sphere_mesh, material = white, cast_shadow = true}

  ground := world.spawn(&app.scene, {0, -0.5, 0})
  ground_body := body_create(app, .staticBody, {0, -0.5})
  ground_box := b2.MakeBox(PLANE_WIDTH, 0.5)
  _ = b2.CreatePolygonShape(ground_body, shape_def(0), &ground_box)
  ground_visual := spawn_visual(app, ground, render.primitive(&app.renderer, .CUBE, .GRAY))
  world.scale(&app.scene, ground_visual, PLANE_WIDTH, 0.5, PLANE_HEIGHT)

  ball := world.spawn(&app.scene, {SPHERE_X, SPHERE_RADIUS, 0})
  ball_body := body_create(app, .staticBody, {SPHERE_X, SPHERE_RADIUS})
  _ = b2.CreateCircleShape(ball_body, shape_def(0), &b2.Circle{radius = SPHERE_RADIUS})
  ball_visual := spawn_visual(app, ball, render.primitive(&app.renderer, .SPHERE, .MAGENTA))
  world.scale(&app.scene, ball_visual, SPHERE_RADIUS)

  unit_box := b2.MakeBox(1, 1)
  upright_cylinder_profile := unit_box
  for x in 0 ..< NX do for y in 0 ..< NY {
    pos := [3]f32{f32(x - NX/2) * 3.0, f32(y) * 3.0 + 10.0, 0}
    i := x * NY + y
    body := body_create(app, .dynamicBody, pos.xy)
    look := cylinder_look
    switch i % 3 {
    case 0:
      _ = b2.CreatePolygonShape(body, shape_def(PIECE_BOX_DENSITY), &upright_cylinder_profile)
    case 1:
      _ = b2.CreatePolygonShape(body, shape_def(PIECE_BOX_DENSITY), &unit_box)
      look = render.primitive(&app.renderer, .CUBE, .RED)
    case 2:
      _ = b2.CreateCircleShape(body, shape_def(PIECE_CIRCLE_DENSITY), &b2.Circle{radius = 1.0})
      look = sphere_look
    }
    node := world.spawn(&app.scene, pos)
    spawn_visual(app, node, look)
    append(&app.pieces, Piece{body, node})
  }
  log.infof("Created %d Box2D bodies", PIECE_COUNT)
  render.camera_look_at(render.main_camera(&app.renderer), {10, 15, 10}, {0, 5, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 5, 0})
  return .READY
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured do render.orbit_drag(&app.orbit, 0, app.input.scroll.y)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  b2.World_Step(app.phys, dt, BOX2D_SUBSTEPS)
  for i := len(app.pieces) - 1; i >= 0; i -= 1 {
    p := app.pieces[i]
    if !b2.Body_IsAwake(p.body) do continue
    pos := b2.Body_GetPosition(p.body)
    if pos.y < KILL_Y {
      b2.DestroyBody(p.body)
      world.destroy(&app.scene, p.node)
      unordered_remove(&app.pieces, i)
      continue
    }
    angle := b2.Rot_GetAngle(b2.Body_GetRotation(p.body))
    world.set_world_pose(&app.scene, p.node, {pos.x, pos.y, 0}, linalg.quaternion_angle_axis_f32(angle, linalg.VECTOR3F32_Z_AXIS))
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
