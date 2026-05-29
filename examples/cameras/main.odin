package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

ControllerMode :: enum {ORBIT, FREE, FOLLOW}

mode: ControllerMode = .ORBIT
follow_controller: mjolnir.CameraController
follow_target: [3]f32 = {0, 0.6, 0}
runner_handle: world.NodeHandle
runner_phase: f32

orbit_distance:    mu.Real = 8.0
free_speed:        mu.Real = 5.0
follow_offset_y:   mu.Real = 3.0
follow_offset_back:mu.Real = 6.0
follow_lerp:       mu.Real = 5.0

main :: proc() {
  mjolnir.run_app({
    title      = "Camera Controllers",
    width      = 1000,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 6, 12}, {0, 0, 0})
  world.spawn_light_directional(&engine.world, position = {6, 12, 6}, color = {1, 0.97, 0.92, 1}, radius = 6.0, cast_shadow = true)
  world.spawn_ground(&engine.world, 20.0)

  spawn_landmark(engine, {-6, 1, 0}, .RED)
  spawn_landmark(engine, {6, 1, 0}, .GREEN)
  spawn_landmark(engine, {0, 1, -6}, .BLUE)
  spawn_landmark(engine, {0, 1, 6}, .YELLOW)

  world.spawn_primitive_mesh(&engine.world, .CUBE, .MAGENTA, position = {0, 0.5, 0})
  runner_handle = world.spawn_primitive_mesh(&engine.world, .SPHERE, .CYAN, position = follow_target, scale_factor = 0.6)
  follow_controller = world.camera_controller_follow_init(engine.window, &follow_target, {0, f32(follow_offset_y), f32(follow_offset_back)}, f32(follow_lerp))

  log.info("Camera controllers — switch live via UI (ORBIT/FREE/FOLLOW)")
}

spawn_landmark :: proc(engine: ^mjolnir.Engine, pos: [3]f32, color: world.Color) {
  world.spawn_primitive_mesh(&engine.world, .CONE, color, position = pos)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  runner_phase += dt * 0.6
  follow_target = {7.0 * math.sin(runner_phase), 0.6, 4.0 * math.sin(runner_phase * 2.0)}
  world.translate(&engine.world, runner_handle, follow_target)

  if orbit, ok := world.orbit_camera(&engine.world); ok {
    orbit.distance = clamp(f32(orbit_distance), orbit.min_distance, orbit.max_distance)
  }
  if free, ok := world.free_camera(&engine.world); ok {
    free.move_speed = f32(free_speed)
  }
  if follow, ok := world.follow_camera_data(&follow_controller); ok {
    follow.offset = {0, f32(follow_offset_y), f32(follow_offset_back)}
    follow.follow_speed = f32(follow_lerp)
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Cameras", {700, 20, 280, 360}, {.NO_CLOSE}) {
    mu.label(ctx, "Controller:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    if .SUBMIT in mu.button(ctx, "Orbit")  do switch_mode(engine, .ORBIT)
    if .SUBMIT in mu.button(ctx, "Free")   do switch_mode(engine, .FREE)
    if .SUBMIT in mu.button(ctx, "Follow") do switch_mode(engine, .FOLLOW)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Active: %v", mode))
    mu.label(ctx, "")
    mu.label(ctx, "Orbit — distance:");        mu.slider(ctx, &orbit_distance, 2.0, 20.0)
    mu.label(ctx, "Free — move speed:");       mu.slider(ctx, &free_speed, 1.0, 30.0)
    mu.label(ctx, "Follow — height offset:");  mu.slider(ctx, &follow_offset_y, 0.5, 10.0)
    mu.label(ctx, "Follow — back offset:");    mu.slider(ctx, &follow_offset_back, 1.0, 15.0)
    mu.label(ctx, "Follow — lerp speed:");     mu.slider(ctx, &follow_lerp, 0.5, 20.0)
    mu.label(ctx, "")
    if cam, ok := world.main_camera(&engine.world); ok {
      mu.label(ctx, fmt.tprintf("Cam pos: %.1f %.1f %.1f", cam.position.x, cam.position.y, cam.position.z))
    }
    mu.label(ctx, fmt.tprintf("Runner: %.1f %.1f %.1f", follow_target.x, follow_target.y, follow_target.z))
  }
}

switch_mode :: proc(engine: ^mjolnir.Engine, new_mode: ControllerMode) {
  if mode == new_mode do return
  mode = new_mode
  switch new_mode {
  case .ORBIT:  world.use_orbit_camera(&engine.world)
  case .FREE:   world.use_free_camera(&engine.world)
  case .FOLLOW: world.use_camera_controller(&engine.world, &follow_controller)
  }
}
