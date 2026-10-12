package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   mjolnir.CameraController,
  input:    input.State,
}

CONTROL_POINTS :: 32
PATH_DEBUG_SAMPLES :: 96

snake:         mjolnir.GltfScene
// one animator (and its path layer) per snake.skinned entry
animators:     [dynamic]animation.Animator
layer_indices: [dynamic]int
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
  defer mjolnir.gltf_scene_destroy(&snake)
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 900, 650, "Path Modifier") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Path Modifier", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = mjolnir.orbit_controller()
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
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
  animation.spline_destroy(&spline)
  spline = animation.spline_build_closed(path_buf[:])
  for &a, i in animators do animation.set_path_params(&a, layer_indices[i], path = path_buf[:])
}

apply_runtime_params :: proc(app: ^App) {
  for &a, i in animators {
    animation.set_path_params(&a, layer_indices[i], offset = f32(offset_val), length = f32(fit_len), speed = 0, loop = true)
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

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {5, 3, 5}, {0, 0, 0})
  snake = mjolnir.load_gltf(&app.scene, &app.renderer, "assets/stuffed_snake_rigged.glb")
  regenerate_points()
  spline = animation.spline_build_closed(path_buf[:])

  for s in snake.skinned {
    rig := &snake.rigs[s.rig]
    a: animation.Animator
    animation.animator_init(&a, rig)
    idx, _ := animation.add_path_layer(&a, rig, "root", 14,
      path = path_buf[:], offset = f32(offset_val), length = f32(fit_len),
      speed = 0, loop = true, closed = true, weight = 1.0,
    )
    append(&animators, a)
    append(&layer_indices, idx)
  }
  ground := world.spawn(&app.scene, {0, -3, 0})
  render.attach(&app.renderer, ground.index, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 30.0)
  light := world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, light.index, render.point_light_attachment({1, 0.9, 0.8, 1}, 15.0, true))
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.debug_ui_input(&app.renderer, &app.input)
  mjolnir.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
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
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  for s, i in snake.skinned do render.stage_bones(&app.renderer, s.node.index, animators[i].palette)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Path Modifier", {20, 20, 200, 380}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Auto play", &auto_play)
    spline_len := animation.spline_arc_length(spline)
    mu.label(ctx, fmt.tprintf("Offset: %.2f / %.2f", f32(offset_val), spline_len))
    if spline_len > 0 do mu.slider(ctx, &offset_val, 0, mu.Real(spline_len))
    mu.label(ctx, fmt.tprintf("Speed: %.2f", speed_val)); mu.slider(ctx, &speed_val, 0, 10)
    mu.label(ctx, fmt.tprintf("Fit length: %.2f", fit_len)); mu.slider(ctx, &fit_len, 0.5, 12)
    mu.label(ctx, fmt.tprintf("Radius: %.2f", radius)); mu.slider(ctx, &radius, 1, 8)
    mu.label(ctx, fmt.tprintf("Height: %.2f", height)); mu.slider(ctx, &height, 0, 6)
    mu.label(ctx, fmt.tprintf("Lobes: %d", int(math.round(f32(lobes))))); mu.slider(ctx, &lobes, 1, 8)
  }
}
