// Procedural bone modifier following a spline.
package main

import "core:log"
import "core:math"
import mu "vendor:microui"
import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/animation"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

CONTROL_POINTS :: 32
PATH_DEBUG_SAMPLES :: 96

SnakeRig :: struct {
  animator: animation.Animator,
  path:     animation.LayerHandle,
}

App :: struct {
  window:     platform.Platform,
  scene:      world.World,
  renderer:   render.Renderer,
  debug:      debugui.Context,
  input:      input.State,
  orbit:      render.Orbit,
  snake_model:  gltf.Model,
  snake:      gltf.Instance,
  rigs:       [dynamic]SnakeRig,
  points:     [CONTROL_POINTS][3]f32,
  spline:     animation.Spline([3]f32),
  offset:     mu.Real,
  speed:      mu.Real,
  fit_length: mu.Real,
  radius:     mu.Real,
  height:     mu.Real,
  lobes:      mu.Real,
  auto_play:  bool,
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
  w := &app.window
  if !platform.init(w, 900, 650, "Path Modifier") do return
  if !render.init(&app.renderer, "Path Modifier", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  for &r in app.rigs do animation.destroy(&r.animator)
  delete(app.rigs)
  animation.destroy(&app.spline)
  gltf.destroy(&app.snake, &app.scene)
  gltf.destroy(&app.snake_model, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  render.camera_look_at(render.main_camera(&app.renderer), {5, 3, 5}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 0, 0})
  ground := world.spawn(&app.scene, {0, -3, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 30.0)
  light := world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_point_light({1, 0.9, 0.8}, 600, 20.0, true)))

  app.snake_model = gltf.model_create(&app.renderer, #load("../../assets/stuffed_snake_rigged.glb"))
  app.snake = gltf.instance_create(&app.snake_model, &app.scene, &app.renderer)
  for s in app.snake.skinned {
    rig := &app.snake_model.rigs[s.rig]
    r: SnakeRig
    animation.animator_init(&r.animator, rig)
    whole_body, _ := animation.bone_chain_down(&rig.skeleton, "root", u32(animation.bone_count(&rig.skeleton)), context.temp_allocator)
    r.path = animation.layer_create(&r.animator, rig, path_params(app), whole_body)
    append(&app.rigs, r)
  }
  rebuild_path(app)
  return .READY
}

path_params :: proc(app: ^App) -> animation.PathParams {
  return {offset = f32(app.offset), length = f32(app.fit_length), loop = true}
}

rebuild_path :: proc(app: ^App) {
  lobes := max(1, math.round(f32(app.lobes)))
  for &p, i in app.points {
    u := f32(i) / CONTROL_POINTS * math.TAU
    p = {f32(app.radius) * math.cos(u), f32(app.height) * math.sin(u * lobes), f32(app.radius) * math.sin(u)}
  }
  animation.destroy(&app.spline)
  animation.spline_init_closed(&app.spline, app.points[:])
  for &r in app.rigs do animation.path_points(&r.animator, r.path, app.points[:], closed = true)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  path_length := animation.spline_arc_length(app.spline)
  if app.auto_play && path_length > 0 {
    app.offset = mu.Real(math.mod_f32(f32(app.offset) + f32(app.speed) * dt, path_length))
  }
  for s, i in app.snake.skinned {
    r := &app.rigs[i]
    if path, ok := animation.layer_params(&r.animator, r.path, animation.PathParams); ok do path^ = path_params(app)
    animation.animator_update(&r.animator, &app.snake_model.rigs[s.rig], dt)
  }
  draw_path(app)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  for s, i in app.snake.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), app.rigs[i].animator.palette)
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
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Path Modifier", {20, 20, 200, 380}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Auto play", &app.auto_play)
    mu.label(ctx, "Offset"); mu.slider(ctx, &app.offset, 0, mu.Real(animation.spline_arc_length(app.spline)))
    mu.label(ctx, "Speed"); mu.slider(ctx, &app.speed, 0, 10)
    mu.label(ctx, "Fit length"); mu.slider(ctx, &app.fit_length, 0.5, 12)
    reshaped: mu.Result_Set
    mu.label(ctx, "Radius"); reshaped |= mu.slider(ctx, &app.radius, 1, 8)
    mu.label(ctx, "Height"); reshaped |= mu.slider(ctx, &app.height, 0, 6)
    mu.label(ctx, "Lobes"); reshaped |= mu.slider(ctx, &app.lobes, 1, 8)
    if .CHANGE in reshaped do rebuild_path(app)
  }
}
