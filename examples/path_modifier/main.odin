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

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

CONTROL_POINTS :: 32
PATH_DEBUG_SAMPLES :: 96

snake:         gltf.Scene
// one animator (and its path layer) per snake.skinned entry
animators:     [dynamic]animation.Animator
layer_indices: [dynamic]animation.LayerHandle
path_buf:      [CONTROL_POINTS][3]f32
spline:        animation.Spline([3]f32)

offset_val: mu.Real = 0
speed_val:  mu.Real = 5
fit_len:    mu.Real = 6
radius:     mu.Real = 4
height:     mu.Real = 2
lobes:      mu.Real = 3
prev_radius: mu.Real = 4
prev_height: mu.Real = 2
prev_lobes:  mu.Real = 3
auto_play: bool = true

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
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
  gltf.destroy(&snake)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

regenerate_points :: proc() {
  lobes_i := max(1, int(math.round(f32(lobes))))
  for i in 0 ..< CONTROL_POINTS {
    t := f32(i) / f32(CONTROL_POINTS)
    u := t * math.PI * 2.0
    path_buf[i] = {f32(radius) * math.cos(u), f32(height) * math.sin(u * f32(lobes_i)), f32(radius) * math.sin(u)}
  }
}

rebuild_path :: proc(app: ^App) {
  regenerate_points()
  animation.destroy(&spline)
  animation.spline_init_closed(&spline, path_buf[:])
  for &a, i in animators do animation.path_points(&a, layer_indices[i], path_buf[:], closed = true)
}

apply_runtime_params :: proc(app: ^App) {
  for &a, i in animators {
    if p, ok := animation.layer_params(&a, layer_indices[i], animation.PathParams); ok do p^ = {offset = f32(offset_val), length = f32(fit_len), loop = true}
  }
}

draw_path_debug :: proc(app: ^App) {
  spline_len := animation.spline_arc_length(spline)
  if spline_len <= 0 do return
  prev := animation.spline_sample_uniform(spline, 0)
  for i in 1 ..= PATH_DEBUG_SAMPLES {
    s := f32(i) / f32(PATH_DEBUG_SAMPLES) * spline_len
    cur := animation.spline_sample_uniform(spline, s)
    render.debug_segment(&app.renderer, prev, cur, color = {1, 0.85, 0.1, 1}, bypass_depth = true)
    prev = cur
  }
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {5, 3, 5}, {0, 0, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  snake = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/stuffed_snake_rigged.glb"))
  regenerate_points()
  animation.spline_init_closed(&spline, path_buf[:])

  for s in snake.skinned {
    rig := &snake.rigs[s.rig]
    a: animation.Animator
    animation.animator_init(&a, rig)
    chain, _ := animation.bone_chain_down(&rig.skeleton, "root", 14, context.temp_allocator)
    idx, _ := animation.layer_create(&a, rig, animation.PathParams{offset = f32(offset_val), length = f32(fit_len), loop = true}, chain)
    animation.path_points(&a, idx, path_buf[:], closed = true)
    append(&animators, a)
    append(&layer_indices, idx)
  }
  ground := world.spawn(&app.scene, {0, -3, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 30.0)
  light := world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_point_light({1, 0.9, 0.8, 1}, 15.0, true)))
  return true
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  if radius != prev_radius || height != prev_height || lobes != prev_lobes {
    rebuild_path(app)
    prev_radius = radius; prev_height = height; prev_lobes = lobes
  }
  spline_len := animation.spline_arc_length(spline)
  if auto_play && spline_len > 0 {
    offset_val = mu.Real(math.mod_f32(f32(offset_val) + f32(speed_val) * dt, spline_len))
    if offset_val < 0 do offset_val += mu.Real(spline_len)
  }
  apply_runtime_params(app)
  for s, i in snake.skinned do animation.animator_update(&animators[i], &snake.rigs[s.rig], dt)
  draw_path_debug(app)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  for s, i in snake.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), animators[i].palette)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Path Modifier", {20, 20, 200, 380}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Auto play", &auto_play)
    spline_len := animation.spline_arc_length(spline)
    mu.label(ctx, "Offset")
    if spline_len > 0 do mu.slider(ctx, &offset_val, 0, mu.Real(spline_len))
    mu.label(ctx, "Speed"); mu.slider(ctx, &speed_val, 0, 10)
    mu.label(ctx, "Fit length"); mu.slider(ctx, &fit_len, 0.5, 12)
    mu.label(ctx, "Radius"); mu.slider(ctx, &radius, 1, 8)
    mu.label(ctx, "Height"); mu.slider(ctx, &height, 0, 6)
    mu.label(ctx, "Lobes"); mu.slider(ctx, &lobes, 1, 8)
  }
}
