// Orbit, free-fly, follow and orthographic top-down cameras built from render camera primitives (orbit, look_at, lerp).
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

CameraMode :: enum {ORBIT, FREE, FOLLOW, TOP}

App :: struct {
  platform:    platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  input:       input.State,
  debug:       debugui.Context,
  mode:        CameraMode,
  orbit:       render.Orbit,
  perspective: render.CameraProjection,
  runner:      world.NodeHandle,
  runner_pos:  [3]f32,
  time:        f32,
}

ORBIT_MIN_DISTANCE :: 2
ORBIT_MAX_DISTANCE :: 40

free_speed:         f32 = 5.0
follow_offset_y:    f32 = 3.0
follow_offset_back: f32 = 6.0
follow_lerp:        f32 = 5.0
top_view_height:    f32 = 16.0
top_yaw:            f32 = 0.0

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.mode = .FOLLOW
  if !platform.init(&app.platform, 1280, 720, "Camera Controllers") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 6, 12}, {0, 0, 0})
  cam := render.main_camera(&app.renderer)
  app.perspective = cam.projection
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, no_shadow = true), scale = 20.0)

  spawn_landmark(app, {-6, 1, 0}, .RED)
  spawn_landmark(app, {6, 1, 0}, .GREEN)
  spawn_landmark(app, {0, 1, -6}, .BLUE)
  spawn_landmark(app, {0, 1, 6}, .YELLOW)

  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .MAGENTA), {0, 0.5, 0})
  app.runner = mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .SPHERE, .CYAN), app.runner_pos, scale = 0.6)
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

spawn_landmark :: proc(app: ^App, pos: [3]f32, color: render.Color) {
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CONE, color), pos)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  app.time += dt
  phase := app.time * 0.6
  app.runner_pos = {7.0 * math.sin(phase), 0.6, 4.0 * math.sin(phase * 2.0)}
  world.transform(&app.scene, app.runner).position = app.runner_pos
  cam := render.main_camera(&app.renderer)
  if !app.input.mouse_captured {
    switch app.mode {
    case .ORBIT:  orbit_camera(app, cam)
    case .FREE:   free_camera(app, cam, dt)
    case .FOLLOW: follow_camera(app, cam, dt)
    case .TOP:    top_camera(app, cam, dt)
    }
  }
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Cameras", {20, 20, 300, 260}) {
    mu.label(ctx, "Controller:")
    mu.layout_row(ctx, {66, 66, 66, 66}, 0)
    names := [CameraMode]string{.ORBIT = "Orbit", .FREE = "Free", .FOLLOW = "Follow", .TOP = "Top"}
    for name, mode in names {
      if .SUBMIT in mu.button(ctx, fmt.tprintf("%s%s", "> " if app.mode == mode else "", name)) do switch_mode(app, mode)
    }
    mu.layout_row(ctx, {-1}, 0)
    switch app.mode {
    case .ORBIT:
      mu.label(ctx, "Distance:")
      mu.slider(ctx, &app.orbit.distance, ORBIT_MIN_DISTANCE, ORBIT_MAX_DISTANCE)
    case .FREE:
      mu.label(ctx, "Move speed:"); mu.slider(ctx, &free_speed, 1.0, 30.0)
    case .FOLLOW:
      mu.label(ctx, "Height offset:"); mu.slider(ctx, &follow_offset_y, 0.5, 10.0)
      mu.label(ctx, "Back offset:"); mu.slider(ctx, &follow_offset_back, 1.0, 15.0)
      mu.label(ctx, "Lerp speed:"); mu.slider(ctx, &follow_lerp, 0.5, 20.0)
    case .TOP:
      mu.label(ctx, "View height:"); mu.slider(ctx, &top_view_height, 4.0, 40.0)
      mu.label(ctx, "Yaw (rad):"); mu.slider(ctx, &top_yaw, -math.PI, math.PI)
    }
  }
}

switch_mode :: proc(app: ^App, mode: CameraMode) {
  if app.mode == mode do return
  cam := render.main_camera(&app.renderer)
  if app.mode == .TOP do cam.projection = app.perspective
  app.mode = mode
  if mode == .ORBIT do app.orbit = render.make_orbit(cam.position, app.orbit.target)
}

orbit_camera :: proc(app: ^App, cam: ^render.Camera) {
  mjolnir.orbit_drag(&app.orbit, cam, &app.input, min_distance = ORBIT_MIN_DISTANCE, max_distance = ORBIT_MAX_DISTANCE)
}

follow_camera :: proc(app: ^App, cam: ^render.Camera, dt: f32) {
  ease := geometry.exp_smooth(follow_lerp, dt)
  from := app.runner_pos + {0, follow_offset_y, follow_offset_back}
  render.camera_lerp_look_at(cam, from, app.runner_pos, ease)
}

free_camera :: proc(app: ^App, cam: ^render.Camera, dt: f32) {
  s := &app.input
  move := linalg.mul(cam.rotation, linalg.VECTOR3F32_X_AXIS) * input.axis(s, .A, .D) + {0, 1, 0} * input.axis(s, .Q, .E) + -linalg.mul(cam.rotation, linalg.VECTOR3F32_Z_AXIS) * input.axis(s, .S, .W)
  cam.position += move * free_speed * dt
  d := s.mouse_delta * 0.002
  cam.rotation = linalg.quaternion_angle_axis(-d.x, linalg.VECTOR3F32_Y_AXIS) * cam.rotation
  cam.rotation = linalg.quaternion_angle_axis(-d.y, linalg.mul(cam.rotation, linalg.VECTOR3F32_X_AXIS)) * cam.rotation
}

top_camera :: proc(app: ^App, cam: ^render.Camera, dt: f32) {
  cam.projection = render.OrthographicProjection{top_view_height}
  up := [3]f32{math.sin(top_yaw), 0, -math.cos(top_yaw)}
  render.camera_lerp_look_at(cam, {0, 30, 0}, {0, 0, 0}, geometry.exp_smooth(follow_lerp, dt), up)
}
