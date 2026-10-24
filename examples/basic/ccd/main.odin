// Continuous collision detection: volleys of fast bullets hit walls of different thickness, and none tunnel through.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "mjolnir/physics"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

WALL_COUNT :: 4
WALL_X :: f32(0.0)
WALL_THICKNESS :: [WALL_COUNT]f32{0.02, 0.05, 0.2, 0.8}
WALL_COLORS :: [WALL_COUNT]render.Color{.RED, .YELLOW, .GREEN, .BLUE}
WALL_HALF_HEIGHT :: f32(1.5)
WALL_HALF_WIDTH :: f32(1.6)
WALL_SPACING :: f32(4.0)
GROUND_HALF_EXTENTS :: [3]f32{30.0, 0.5, 12.0}
BULLET_RADIUS :: f32(0.15)
BULLET_MASS :: f32(0.05)
START_X :: f32(-15.0)
BULLET_HEIGHT :: f32(1.5)
DEFAULT_SPEED :: 400
VOLLEY_SECONDS :: f32(2.5)
TRACER_SECONDS :: f32(VOLLEY_SECONDS)

App :: struct {
  platform:     platform.Platform,
  scene:        world.World,
  renderer:     render.Renderer,
  debug:        debugui.Context,
  input:        input.State,
  orbit:        render.Orbit,
  phys:         physics.World,
  bullets:      [WALL_COUNT]physics.BodyHandle,
  volley_timer: f32,
  speed:        f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.speed = DEFAULT_SPEED
  if !physics.init(&app.phys, gravity = {0, 0, 0}) do return
  if !platform.init(&app.platform, 1000, 700, "Bullet vs Thin Wall (CCD)") do return
  if !render.init(&app.renderer, app.platform.window) do return
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
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  physics.shutdown(&app.phys)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

spawn_box :: proc(app: ^App, position, half_extents: [3]f32, color: render.Color) {
  node := world.spawn(&app.scene, position)
  physics.body_create(&app.phys, position, collider = physics.BoxCollider{half_extents = half_extents}, user = world.Handle(node))
  visual := world.spawn(&app.scene, parent = node)
  render.attach(&app.renderer, render.SlotHandle(visual.index), render.primitive(&app.renderer, .CUBE, color))
  world.scale(&app.scene, visual, half_extents)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer, {1000, 700}) do return .FAIL
  app.orbit = render.make_orbit({-12, 7, 13}, {0, 1, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  spawn_box(app, {0, -GROUND_HALF_EXTENTS.y, 0}, GROUND_HALF_EXTENTS, .GRAY)
  thickness := WALL_THICKNESS
  colors := WALL_COLORS
  for i in 0 ..< WALL_COUNT {
    spawn_box(app, {WALL_X, WALL_HALF_HEIGHT, wall_z(i)}, {thickness[i] * 0.5, WALL_HALF_HEIGHT, WALL_HALF_WIDTH}, colors[i])
    spawn_bullet(app, i, colors[i])
  }
  start_volley(app)
  return .READY
}

spawn_bullet :: proc(app: ^App, lane: int, color: render.Color) {
  position := [3]f32{START_X, BULLET_HEIGHT, wall_z(lane)}
  node := world.spawn(&app.scene, position)
  handle := physics.body_create(&app.phys, position, mass = BULLET_MASS, collider = physics.SphereCollider{radius = BULLET_RADIUS}, user = world.Handle(node))
  visual := world.spawn(&app.scene, parent = node)
  render.attach(&app.renderer, render.SlotHandle(visual.index), render.primitive(&app.renderer, .SPHERE, color))
  world.scale(&app.scene, visual, BULLET_RADIUS)
  params := physics.body_params(&app.phys, handle)
  params.linear_damping = 0
  params.angular_damping = 0
  params.restitution = 0.1
  params.friction = 0.2
  app.bullets[lane] = handle
}

wall_z :: proc(wall: int) -> f32 {
  return (f32(wall) - f32(WALL_COUNT - 1) * 0.5) * WALL_SPACING
}

start_volley :: proc(app: ^App) {
  app.volley_timer = 0
  for bullet, i in app.bullets {
    physics.set_pose(&app.phys, bullet, {START_X, BULLET_HEIGHT, wall_z(i)}, linalg.QUATERNIONF32_IDENTITY)
    physics.set_velocity(&app.phys, bullet, {app.speed, 0, 0})
    physics.set_angular_velocity(&app.phys, bullet, {})
  }
}

draw_tracers :: proc(app: ^App, previous: [WALL_COUNT][3]f32) {
  colors := [WALL_COUNT][4]f32{{1, 0.2, 0.2, 1}, {1, 0.9, 0.2, 1}, {0.2, 1, 0.3, 1}, {0.3, 0.5, 1, 1}}
  for bullet, i in app.bullets {
    body := physics.body(&app.phys, bullet) or_continue
    render.debug_segment(&app.renderer, previous[i], body.position, colors[i], TRACER_SECONDS)
  }
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, &app.input)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.volley_timer += dt
  if app.volley_timer >= VOLLEY_SECONDS do start_volley(app)
  previous: [WALL_COUNT][3]f32
  for bullet, i in app.bullets do previous[i] = physics.body(&app.phys, bullet).position
  physics.step(&app.phys, dt)
  draw_tracers(app, previous)
  world.set_world_poses(&app.scene, physics.body_poses(&app.phys))
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "CCD", {700, 20, 280, 120}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Velocity (m/s)")
    mu.slider(ctx, &app.speed, 1.0, 1000.0)
    if .SUBMIT in mu.button(ctx, "Fire") do start_volley(app)
  }
}
