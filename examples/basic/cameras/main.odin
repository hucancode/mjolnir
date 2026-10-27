// Orbit, free-fly and follow cameras built from render camera primitives (orbit, look_at, lerp).
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

CameraMode :: enum {ORBIT, FREE, FOLLOW}

App :: struct {
  platform:   platform.Platform,
  scene:      world.World,
  renderer:   render.Renderer,
  debug:      debugui.Context,
  input:      input.State,
  mode:       CameraMode,
  orbit:      render.Orbit,
  runner:     world.NodeHandle,
  runner_pos: [3]f32,
  time:       f32,
}

ORBIT_MIN_DISTANCE :: 2
ORBIT_MAX_DISTANCE :: 40

orbit_distance:     f32 = 8.0
free_speed:         f32 = 5.0
follow_offset_y:    f32 = 3.0
follow_offset_back: f32 = 6.0
follow_lerp:        f32 = 5.0

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.mode = .FOLLOW
  if !platform.init(&app.platform, 1000, 700, "Camera Controllers") do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 6, 12}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  orbit_distance = app.orbit.distance
  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)

  spawn_landmark(app, {-6, 1, 0}, .RED)
  spawn_landmark(app, {6, 1, 0}, .GREEN)
  spawn_landmark(app, {0, 1, -6}, .BLUE)
  spawn_landmark(app, {0, 1, 6}, .YELLOW)

  cube := world.spawn(&app.scene, {0, 0.5, 0})
  render.attach(&app.renderer, render.SlotHandle(cube.index), render.primitive(&app.renderer, .CUBE, .MAGENTA))
  app.runner = world.spawn(&app.scene, app.runner_pos)
  render.attach(&app.renderer, render.SlotHandle(app.runner.index), render.primitive(&app.renderer, .SPHERE, .CYAN))
  world.scale(&app.scene, app.runner, 0.6)
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

spawn_landmark :: proc(app: ^App, pos: [3]f32, color: render.Color) {
  n := world.spawn(&app.scene, pos)
  render.attach(&app.renderer, render.SlotHandle(n.index), render.primitive(&app.renderer, .CONE, color))
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  app.time += dt
  phase := app.time * 0.6
  app.runner_pos = {7.0 * math.sin(phase), 0.6, 4.0 * math.sin(phase * 2.0)}
  world.translate(&app.scene, app.runner, app.runner_pos)
  cam := render.main_camera(&app.renderer)
  if !app.input.mouse_captured {
    switch app.mode {
    case .ORBIT:  orbit_camera(app, cam)
    case .FREE:   free_camera(app, cam, dt)
    case .FOLLOW: follow_camera(app, cam, dt)
    }
  }
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
  if debugui.window(&app.debug, "Cameras", {680, 20, 300, 260}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.label(ctx, "Controller:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    names := [CameraMode]string{.ORBIT = "Orbit", .FREE = "Free", .FOLLOW = "Follow"}
    for name, mode in names {
      if .SUBMIT in mu.button(ctx, fmt.tprintf("%s%s", "> " if app.mode == mode else "", name)) do switch_mode(app, mode)
    }
    mu.layout_row(ctx, {-1}, 0)
    switch app.mode {
    case .ORBIT:
      mu.label(ctx, "Distance:")
      if .CHANGE in mu.slider(ctx, &orbit_distance, ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE) do app.orbit.distance = orbit_distance
    case .FREE:
      mu.label(ctx, "Move speed:"); mu.slider(ctx, &free_speed, 1.0, 30.0)
    case .FOLLOW:
      mu.label(ctx, "Height offset:"); mu.slider(ctx, &follow_offset_y, 0.5, 10.0)
      mu.label(ctx, "Back offset:"); mu.slider(ctx, &follow_offset_back, 1.0, 15.0)
      mu.label(ctx, "Lerp speed:"); mu.slider(ctx, &follow_lerp, 0.5, 20.0)
    }
  }
}

switch_mode :: proc(app: ^App, mode: CameraMode) {
  if app.mode == mode do return
  app.mode = mode
  if mode == .ORBIT {
    app.orbit = render.make_orbit(render.main_camera(&app.renderer).position, app.orbit.target)
    orbit_distance = app.orbit.distance
  }
}

orbit_camera :: proc(app: ^App, cam: ^render.Camera) {
  render.orbit_drag(&app.orbit, &app.input, min_distance = ORBIT_MIN_DISTANCE, max_distance = ORBIT_MAX_DISTANCE)
  orbit_distance = app.orbit.distance
  render.camera_orbit(cam, app.orbit)
}

follow_camera :: proc(app: ^App, cam: ^render.Camera, dt: f32) {
  ease := 1 - math.exp(-follow_lerp * dt)
  from := app.runner_pos + {0, follow_offset_y, follow_offset_back}
  render.camera_lerp_look_at(cam, from, app.runner_pos, ease)
}

free_camera :: proc(app: ^App, cam: ^render.Camera, dt: f32) {
  s := &app.input
  move := render.camera_right(cam) * input.axis(s, .A, .D) + {0, 1, 0} * input.axis(s, .Q, .E) + render.camera_forward(cam) * input.axis(s, .S, .W)
  cam.position += move * free_speed * dt
  d := s.mouse_delta * 0.002
  cam.rotation = linalg.quaternion_angle_axis(-d.x, linalg.VECTOR3F32_Y_AXIS) * cam.rotation
  cam.rotation = linalg.quaternion_angle_axis(-d.y, render.camera_right(cam)) * cam.rotation
}
