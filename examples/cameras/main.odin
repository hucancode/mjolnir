package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

ControllerMode :: enum {ORBIT, FREE, FOLLOW}

mode: ControllerMode = .ORBIT
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
  render.main_camera_look_at(&engine.render, {0, 6, 12}, {0, 0, 0})
  mjolnir.spawn(engine, {6, 12, 6}, render.directional_light_attachment(color = {1, 0.97, 0.92, 1}, radius = 6.0, cast_shadow = true))
  mjolnir.spawn_ground(engine, 20.0)

  spawn_landmark(engine, {-6, 1, 0}, .RED)
  spawn_landmark(engine, {6, 1, 0}, .GREEN)
  spawn_landmark(engine, {0, 1, -6}, .BLUE)
  spawn_landmark(engine, {0, 1, 6}, .YELLOW)

  mjolnir.spawn_primitive_mesh(engine, .CUBE, .MAGENTA, position = {0, 0.5, 0})
  runner_handle = mjolnir.spawn_primitive_mesh(engine, .SPHERE, .CYAN, position = follow_target, scale_factor = 0.6)

  log.info("Camera controllers — switch live via UI (ORBIT/FREE/FOLLOW)")
}

spawn_landmark :: proc(engine: ^mjolnir.Engine, pos: [3]f32, color: render.Color) {
  mjolnir.spawn_primitive_mesh(engine, .CONE, color, position = pos)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  runner_phase += dt * 0.6
  follow_target = {7.0 * math.sin(runner_phase), 0.6, 4.0 * math.sin(runner_phase * 2.0)}
  world.translate(&engine.world, runner_handle, follow_target)

  if free, ok := &engine.camera_controller.data.(render.FreeCameraData); ok {
    free.move_speed = f32(free_speed)
  }
  if follow, ok := &engine.camera_controller.data.(render.FollowCameraData); ok {
    follow.target = follow_target
    follow.offset = {0, f32(follow_offset_y), f32(follow_offset_back)}
    follow.follow_speed = f32(follow_lerp)
  }
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Cameras", {700, 20, 280, 360}, {.NO_CLOSE}) {
    mu.label(ctx, "Controller:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    if .SUBMIT in mu.button(ctx, "Orbit")  do switch_mode(engine, .ORBIT)
    if .SUBMIT in mu.button(ctx, "Free")   do switch_mode(engine, .FREE)
    if .SUBMIT in mu.button(ctx, "Follow") do switch_mode(engine, .FOLLOW)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Active: %v", mode))
    mu.label(ctx, "")
    mu.label(ctx, "Orbit — distance:")
    if .CHANGE in mu.slider(ctx, &orbit_distance, 2.0, 20.0) do set_orbit_distance(engine)
    mu.label(ctx, "Free — move speed:");       mu.slider(ctx, &free_speed, 1.0, 30.0)
    mu.label(ctx, "Follow — height offset:");  mu.slider(ctx, &follow_offset_y, 0.5, 10.0)
    mu.label(ctx, "Follow — back offset:");    mu.slider(ctx, &follow_offset_back, 1.0, 15.0)
    mu.label(ctx, "Follow — lerp speed:");     mu.slider(ctx, &follow_lerp, 0.5, 20.0)
    mu.label(ctx, "")
    if cam, ok := render.main_camera(&engine.render); ok {
      mu.label(ctx, fmt.tprintf("Cam pos: %.1f %.1f %.1f", cam.position.x, cam.position.y, cam.position.z))
    }
    mu.label(ctx, fmt.tprintf("Runner: %.1f %.1f %.1f", follow_target.x, follow_target.y, follow_target.z))
  }
}

switch_mode :: proc(engine: ^mjolnir.Engine, new_mode: ControllerMode) {
  if mode == new_mode do return
  mode = new_mode
  switch new_mode {
  case .ORBIT:  engine.camera_controller = render.orbit_controller()
  case .FREE:   engine.camera_controller = render.free_controller(f32(free_speed))
  case .FOLLOW: engine.camera_controller = render.follow_controller(follow_target, {0, f32(follow_offset_y), f32(follow_offset_back)}, f32(follow_lerp))
  }
}

// Orbit distance is the camera's distance to the orbit target; move along the view ray.
set_orbit_distance :: proc(engine: ^mjolnir.Engine) {
  orbit, is_orbit := engine.camera_controller.data.(render.OrbitCameraData)
  cam, has_cam := render.main_camera(&engine.render)
  if !is_orbit || !has_cam do return
  dir := linalg.normalize(cam.position - orbit.target)
  render.camera_look_at(cam, orbit.target + dir * f32(orbit_distance), orbit.target)
}
