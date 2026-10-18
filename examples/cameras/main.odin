// Orbit, free-fly and follow cameras built from render camera primitives (orbit, look_at, lerp).
package main

import "../../mjolnir"
import geom "../../mjolnir/geometry"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

CameraMode :: enum {ORBIT, FREE, FOLLOW}

App :: struct {
  window:     platform.Platform,
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

orbit_distance:     mu.Real = 8.0
free_speed:         mu.Real = 5.0
follow_offset_y:    mu.Real = 3.0
follow_offset_back: mu.Real = 6.0
follow_lerp:        mu.Real = 5.0

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1000, 700, "Camera Controllers") do return
  if !render.init(&app.renderer, "Camera Controllers", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 6, 12}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))
  orbit_distance = mu.Real(app.orbit.distance)
  sun := world.spawn(&app.scene, {6, 12, 6})
  render.attach(&app.renderer, render.SlotHandle(sun.index), render.light_create(&app.renderer, render.make_directional_light(color = {1, 0.97, 0.92}, shadow_radius = 6.0)))
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
  return true
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

spawn_landmark :: proc(app: ^App, pos: [3]f32, color: render.Color) {
  n := world.spawn(&app.scene, pos)
  render.attach(&app.renderer, render.SlotHandle(n.index), render.primitive(&app.renderer, .CONE, color))
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
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
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Cameras", {700, 20, 280, 360}, {.NO_CLOSE}) {
    mu.label(ctx, "Controller:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    if .SUBMIT in mu.button(ctx, "Orbit")  do switch_mode(app, .ORBIT)
    if .SUBMIT in mu.button(ctx, "Free")   do switch_mode(app, .FREE)
    if .SUBMIT in mu.button(ctx, "Follow") do switch_mode(app, .FOLLOW)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Active: %v", app.mode))
    mu.label(ctx, "")
    mu.label(ctx, "Orbit: distance:")
    if .CHANGE in mu.slider(ctx, &orbit_distance, ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE) do app.orbit.distance = f32(orbit_distance)
    mu.label(ctx, "Free: move speed:"); mu.slider(ctx, &free_speed, 1.0, 30.0)
    mu.label(ctx, "Follow: height offset:"); mu.slider(ctx, &follow_offset_y, 0.5, 10.0)
    mu.label(ctx, "Follow: back offset:"); mu.slider(ctx, &follow_offset_back, 1.0, 15.0)
    mu.label(ctx, "Follow: lerp speed:"); mu.slider(ctx, &follow_lerp, 0.5, 20.0)
    mu.label(ctx, "")
    cam := render.main_camera(&app.renderer)
    mu.label(ctx, fmt.tprintf("Cam pos: %.1f %.1f %.1f", cam.position.x, cam.position.y, cam.position.z))
    mu.label(ctx, fmt.tprintf("Runner: %.1f %.1f %.1f", app.runner_pos.x, app.runner_pos.y, app.runner_pos.z))
  }
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

switch_mode :: proc(app: ^App, mode: CameraMode) {
  if app.mode == mode do return
  app.mode = mode
  if mode == .ORBIT {
    app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))
    orbit_distance = mu.Real(app.orbit.distance)
  }
}

orbit_camera :: proc(app: ^App, cam: ^render.Camera) {
  drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
  render.orbit_drag(&app.orbit, drag, app.input.scroll.y, min_distance = ORBIT_MIN_DISTANCE, max_distance = ORBIT_MAX_DISTANCE)
  orbit_distance = mu.Real(app.orbit.distance)
  render.camera_orbit(cam, app.orbit)
}

follow_camera :: proc(app: ^App, cam: ^render.Camera, dt: f32) {
  ease := 1 - math.exp(-f32(follow_lerp) * dt)
  from := app.runner_pos + {0, f32(follow_offset_y), f32(follow_offset_back)}
  render.camera_lerp_look_at(cam, from, app.runner_pos, ease)
}

free_camera :: proc(app: ^App, cam: ^render.Camera, dt: f32) {
  s := &app.input
  move := geom.qx(cam.rotation) * input.axis(s, .A, .D) + {0, 1, 0} * input.axis(s, .Q, .E) - geom.qz(cam.rotation) * input.axis(s, .S, .W)
  cam.position += move * f32(free_speed) * dt
  d := s.mouse_delta * 0.002
  cam.rotation = linalg.quaternion_angle_axis(-d.x, linalg.VECTOR3F32_Y_AXIS) * cam.rotation
  cam.rotation = linalg.quaternion_angle_axis(-d.y, geom.qx(cam.rotation)) * cam.rotation
}
