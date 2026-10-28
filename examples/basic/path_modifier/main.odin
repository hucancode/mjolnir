// Procedural bone modifier following a spline.
package main

import "core:log"
import "core:math"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/animation"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

CONTROL_POINTS :: 32
PATH_DEBUG_SAMPLES :: 96

App :: struct {
  platform:    platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  debug:       debugui.Context,
  input:       input.State,
  orbit:       render.Orbit,
  snake_model: gltf.Model,
  snake:       gltf.Instance,
  path:        animation.LayerHandle,
  points:      [CONTROL_POINTS][3]f32,
  spline:      animation.Spline([3]f32),
  offset:      f32,
  speed:       f32,
  fit_length:  f32,
  radius:      f32,
  height:      f32,
  lobes:       f32,
  auto_play:   bool,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.speed = 5
  app.fit_length = 6
  app.radius = 4
  app.height = 2
  app.lobes = 3
  app.auto_play = true
  if !platform.init(&app.platform, 1280, 720, "Path Modifier") do return
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
  animation.destroy(&app.spline)
  gltf.destroy(&app.snake, &app.scene, &app.renderer)
  gltf.destroy(&app.snake_model, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({5, 3, 5}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false), {0, -3, 0}, scale = 30.0)

  app.snake_model = gltf.model_create(&app.renderer, #load("assets/stuffed_snake_rigged.glb"))
  app.snake = gltf.instance_create(&app.snake_model, &app.scene, &app.renderer)
  if len(app.snake.animators) == 0 do return .FAIL
  rig := &app.snake_model.rigs[0]
  whole_body, _ := animation.bone_chain_down(&rig.skeleton, "root", u32(animation.bone_count(&rig.skeleton)), context.temp_allocator)
  app.path = animation.layer_create(&app.snake.animators[0], rig, path_params(app), whole_body)
  rebuild_path(app)
  return .READY
}

path_params :: proc(app: ^App) -> animation.PathParams {
  return {offset = app.offset, length = app.fit_length, loop = true}
}

rebuild_path :: proc(app: ^App) {
  lobes := max(1, math.round(app.lobes))
  for &p, i in app.points {
    u := f32(i) / CONTROL_POINTS * math.TAU
    p = {app.radius * math.cos(u), app.height * math.sin(u * lobes), app.radius * math.sin(u)}
  }
  animation.destroy(&app.spline)
  animation.spline_init_closed(&app.spline, app.points[:])
  animation.path_points(&app.snake.animators[0], app.path, app.points[:], closed = true)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  path_length := animation.spline_arc_length(app.spline)
  if app.auto_play && path_length > 0 {
    app.offset = math.mod_f32(app.offset + app.speed * dt, path_length)
  }
  if path, ok := animation.layer_params(&app.snake.animators[0], app.path, animation.PathParams); ok do path^ = path_params(app)
  draw_path(app)
  world.update(&app.scene)
  gltf.animate(&app.snake, &app.snake_model, &app.scene, &app.renderer, dt)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

draw_path :: proc(app: ^App) {
  path_length := animation.spline_arc_length(app.spline)
  if path_length <= 0 do return
  prev := animation.spline_sample_uniform(app.spline, 0)
  for i in 1 ..= PATH_DEBUG_SAMPLES {
    cur := animation.spline_sample_uniform(app.spline, f32(i) / PATH_DEBUG_SAMPLES * path_length)
    render.debug_segment(&app.renderer, prev, cur, color = {1, 0.85, 0.1, 1}, bypass_depth = true)
    prev = cur
  }
}

frame :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Path Modifier", {20, 20, 200, 380}, {}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Auto play", &app.auto_play)
    mu.label(ctx, "Offset"); mu.slider(ctx, &app.offset, 0, animation.spline_arc_length(app.spline))
    mu.label(ctx, "Speed"); mu.slider(ctx, &app.speed, 0, 10)
    mu.label(ctx, "Fit length"); mu.slider(ctx, &app.fit_length, 0.5, 12)
    reshaped: mu.Result_Set
    mu.label(ctx, "Radius"); reshaped |= mu.slider(ctx, &app.radius, 1, 8)
    mu.label(ctx, "Height"); reshaped |= mu.slider(ctx, &app.height, 0, 6)
    mu.label(ctx, "Lobes"); reshaped |= mu.slider(ctx, &app.lobes, 1, 8)
    if .CHANGE in reshaped do rebuild_path(app)
  }
}
