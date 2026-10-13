// Orbit, free-fly and follow cameras built from render camera primitives (orbit, look_at, lerp).
package main

import "../../mjolnir"
import geom "../../mjolnir/geometry"
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

mode: CameraMode = .ORBIT
follow_target: [3]f32 = {0, 0.6, 0}
runner_handle: world.NodeHandle
runner_phase: f32

orbit_distance:    mu.Real = 8.0
free_speed:        mu.Real = 5.0
follow_offset_y:   mu.Real = 3.0
follow_offset_back:mu.Real = 6.0
follow_lerp:       mu.Real = 5.0

// The whole "controller": orbit state is just yaw/pitch/distance around a target.
orbit_state :: struct {
  yaw, pitch, distance: f32,
}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  orbit:    orbit_state,
  input:    input.State,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 1000, 700, "Camera Controllers") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Camera Controllers", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")

  render.main_camera_look_at(&app.renderer, {0, 6, 12}, {0, 0, 0})
  if cam, ok := render.main_camera(&app.renderer); ok {
    app.orbit.yaw, app.orbit.pitch, app.orbit.distance = render.camera_orbit_state(cam)
  }
  sun := world.spawn(&app.scene, {6, 12, 6})
  render.attach(&app.renderer, sun.index, render.directional_light_attachment(color = {1, 0.97, 0.92, 1}, shadow_radius = 6.0, cast_shadow = true))
  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)

  spawn_landmark(app, {-6, 1, 0}, .RED)
  spawn_landmark(app, {6, 1, 0}, .GREEN)
  spawn_landmark(app, {0, 1, -6}, .BLUE)
  spawn_landmark(app, {0, 1, 6}, .YELLOW)

  cube := world.spawn(&app.scene, {0, 0.5, 0})
  render.attach(&app.renderer, cube.index, render.primitive(&app.renderer, .CUBE, .MAGENTA))
  runner_handle = world.spawn(&app.scene, follow_target)
  render.attach(&app.renderer, runner_handle.index, render.primitive(&app.renderer, .SPHERE, .CYAN))
  world.scale(&app.scene, runner_handle, 0.6)

  log.info("Camera controllers — switch live via UI (ORBIT/FREE/FOLLOW)")

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

spawn_landmark :: proc(app: ^App, pos: [3]f32, color: render.Color) {
  n := world.spawn(&app.scene, pos)
  render.attach(&app.renderer, n.index, render.primitive(&app.renderer, .CONE, color))
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  runner_phase += dt * 0.6
  follow_target = {7.0 * math.sin(runner_phase), 0.6, 4.0 * math.sin(runner_phase * 2.0)}
  world.translate(&app.scene, runner_handle, follow_target)
  if cam, ok := render.main_camera(&app.renderer); ok && !app.input.mouse_captured {
    switch mode {
    case .ORBIT: orbit_camera(app, cam)
    case .FREE:  free_camera(app, cam, dt)
    case .FOLLOW:
      // pose chases a point behind/above the runner; position and rotation both ease
      t := 1 - math.exp(-f32(follow_lerp) * dt)
      from := follow_target + {0, f32(follow_offset_y), f32(follow_offset_back)}
      render.camera_lerp_look_at(cam, from, follow_target, t)
    }
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Cameras", {700, 20, 280, 360}, {.NO_CLOSE}) {
    mu.label(ctx, "Controller:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    if .SUBMIT in mu.button(ctx, "Orbit")  do switch_mode(app, .ORBIT)
    if .SUBMIT in mu.button(ctx, "Free")   do switch_mode(app, .FREE)
    if .SUBMIT in mu.button(ctx, "Follow") do switch_mode(app, .FOLLOW)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Active: %v", mode))
    mu.label(ctx, "")
    mu.label(ctx, "Orbit — distance:")
    if .CHANGE in mu.slider(ctx, &orbit_distance, 2.0, 20.0) do set_orbit_distance(app)
    mu.label(ctx, "Free — move speed:");       mu.slider(ctx, &free_speed, 1.0, 30.0)
    mu.label(ctx, "Follow — height offset:");  mu.slider(ctx, &follow_offset_y, 0.5, 10.0)
    mu.label(ctx, "Follow — back offset:");    mu.slider(ctx, &follow_offset_back, 1.0, 15.0)
    mu.label(ctx, "Follow — lerp speed:");     mu.slider(ctx, &follow_lerp, 0.5, 20.0)
    mu.label(ctx, "")
    if cam, ok := render.main_camera(&app.renderer); ok {
      mu.label(ctx, fmt.tprintf("Cam pos: %.1f %.1f %.1f", cam.position.x, cam.position.y, cam.position.z))
    }
    mu.label(ctx, fmt.tprintf("Runner: %.1f %.1f %.1f", follow_target.x, follow_target.y, follow_target.z))
  }
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

switch_mode :: proc(app: ^App, new_mode: CameraMode) {
  if mode == new_mode do return
  mode = new_mode
  if cam, ok := render.main_camera(&app.renderer); ok && new_mode == .ORBIT {
    app.orbit.yaw, app.orbit.pitch, app.orbit.distance = render.camera_orbit_state(cam)
    orbit_distance = mu.Real(app.orbit.distance)
  }
}

// Orbit distance is the camera's distance to the origin.
set_orbit_distance :: proc(app: ^App) {
  app.orbit.distance = f32(orbit_distance)
}

orbit_camera :: proc(app: ^App, cam: ^render.Camera) {
  o := &app.orbit
  if input.mouse_down(&app.input, .LEFT) {
    d := app.input.mouse_delta * 0.02
    o.yaw += d.x
    o.pitch = clamp(o.pitch + d.y, -1.5, 1.5)
  }
  o.distance = clamp(o.distance - app.input.scroll.y * 2, 2, 40)
  render.camera_orbit(cam, o.yaw, o.pitch, o.distance)
}

free_camera :: proc(app: ^App, cam: ^render.Camera, dt: f32) {
  s := &app.input
  move := geom.qx(cam.rotation) * input.axis(s, .A, .D) + {0, 1, 0} * input.axis(s, .Q, .E) - geom.qz(cam.rotation) * input.axis(s, .S, .W)
  cam.position += move * f32(free_speed) * dt
  d := s.mouse_delta * 0.002
  cam.rotation = linalg.quaternion_angle_axis(-d.x, linalg.VECTOR3F32_Y_AXIS) * cam.rotation
  cam.rotation = linalg.quaternion_angle_axis(-d.y, geom.qx(cam.rotation)) * cam.rotation
}
