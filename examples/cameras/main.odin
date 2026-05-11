package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

ControllerMode :: enum {
  ORBIT,
  FREE,
  FOLLOW,
}

mode: ControllerMode = .ORBIT
follow_controller: world.CameraController
follow_target: [3]f32 = {0, 0.6, 0}
runner_handle: world.NodeHandle
runner_phase: f32

orbit_distance: mu.Real = 8.0
free_speed: mu.Real = 5.0
follow_offset_y: mu.Real = 3.0
follow_offset_back: mu.Real = 6.0
follow_lerp: mu.Real = 5.0

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 1000, 700, "Camera Controllers")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(&engine.world, {0, 6, 12}, {0, 0, 0})

  world.spawn(
    &engine.world,
    {6, 12, 6},
    world.create_directional_light_attachment({1, 0.97, 0.92, 1}, 6.0, true),
  )

  ground_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.MeshAttachment{handle = ground_mesh, material = ground_mat},
    ) or_else {}
  world.scale(&engine.world, ground, 20.0)

  // Landmarks at known coords so orientation is obvious when switching cams
  spawn_landmark(&engine.world, {-6, 1, 0}, .RED)
  spawn_landmark(&engine.world, {6, 1, 0}, .GREEN)
  spawn_landmark(&engine.world, {0, 1, -6}, .BLUE)
  spawn_landmark(&engine.world, {0, 1, 6}, .YELLOW)

  // Center cube — orbit target
  world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .MAGENTA,
    position = {0, 0.5, 0},
  )

  // Runner — moves along a figure-8, target for FOLLOW
  runner_handle = world.spawn_primitive_mesh(
    &engine.world,
    .SPHERE,
    .CYAN,
    position = follow_target,
    scale_factor = 0.6,
  )

  // Pre-init follow controller pointing at moving runner
  follow_controller = world.camera_controller_follow_init(
    engine.window,
    &follow_target,
    {0, f32(follow_offset_y), f32(follow_offset_back)},
    f32(follow_lerp),
  )

  log.info("=========================================")
  log.info("Camera controllers — switch live via UI")
  log.info("  ORBIT  : drag LMB to rotate, scroll to zoom")
  log.info("  FREE   : WASD + LMB drag to fly")
  log.info("  FOLLOW : tracks moving cyan sphere")
  log.info("=========================================")
}

spawn_landmark :: proc(w: ^world.World, pos: [3]f32, color: world.Color) {
  world.spawn_primitive_mesh(w, .CONE, color, position = pos)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  runner_phase += delta_time * 0.6
  // Figure-8 path on XZ plane
  follow_target = {
    7.0 * math.sin(runner_phase),
    0.6,
    4.0 * math.sin(runner_phase * 2.0),
  }
  if rn, ok := world.node(&engine.world, runner_handle); ok {
    world.translate(&rn.transform, follow_target.x, follow_target.y, follow_target.z)
  }

  // Live-update controller params from sliders, no rebuild
  if orbit, ok := &engine.world.orbit_controller.data.(world.OrbitCameraData);
     ok {
    orbit.distance = clamp(
      f32(orbit_distance),
      orbit.min_distance,
      orbit.max_distance,
    )
  }
  if free, ok := &engine.world.free_controller.data.(world.FreeCameraData);
     ok {
    free.move_speed = f32(free_speed)
  }
  if follow, ok := &follow_controller.data.(world.FollowCameraData); ok {
    follow.offset = {0, f32(follow_offset_y), f32(follow_offset_back)}
    follow.follow_speed = f32(follow_lerp)
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "Cameras", {700, 20, 280, 360}, {.NO_CLOSE}) {
    mu.label(ctx, "Controller:")
    mu.layout_row(ctx, {90, 90, 90}, 0)
    if .SUBMIT in mu.button(ctx, "Orbit") do switch_mode(engine, .ORBIT)
    if .SUBMIT in mu.button(ctx, "Free") do switch_mode(engine, .FREE)
    if .SUBMIT in mu.button(ctx, "Follow") do switch_mode(engine, .FOLLOW)

    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Active: %v", mode))

    mu.label(ctx, "")
    mu.label(ctx, "Orbit — distance:")
    mu.slider(ctx, &orbit_distance, 2.0, 20.0)

    mu.label(ctx, "Free — move speed:")
    mu.slider(ctx, &free_speed, 1.0, 30.0)

    mu.label(ctx, "Follow — height offset:")
    mu.slider(ctx, &follow_offset_y, 0.5, 10.0)
    mu.label(ctx, "Follow — back offset:")
    mu.slider(ctx, &follow_offset_back, 1.0, 15.0)
    mu.label(ctx, "Follow — lerp speed:")
    mu.slider(ctx, &follow_lerp, 0.5, 20.0)

    mu.label(ctx, "")
    if main_cam := world.camera(&engine.world, engine.world.main_camera); main_cam != nil {
      mu.label(
        ctx,
        fmt.tprintf(
          "Cam pos: %.1f %.1f %.1f",
          main_cam.position.x,
          main_cam.position.y,
          main_cam.position.z,
        ),
      )
    }
    mu.label(
      ctx,
      fmt.tprintf(
        "Runner: %.1f %.1f %.1f",
        follow_target.x,
        follow_target.y,
        follow_target.z,
      ),
    )
  }
}

switch_mode :: proc(engine: ^mjolnir.Engine, new_mode: ControllerMode) {
  if mode == new_mode do return
  mode = new_mode
  main_cam := world.camera(&engine.world, engine.world.main_camera)
  if main_cam == nil do return

  switch new_mode {
  case .ORBIT:
    world.camera_controller_orbit_sync(&engine.world.orbit_controller, main_cam)
    engine.world.active_controller = &engine.world.orbit_controller
  case .FREE:
    engine.world.active_controller = &engine.world.free_controller
  case .FOLLOW:
    engine.world.active_controller = &follow_controller
  }
}
