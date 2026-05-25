package main

import "../../mjolnir"
import "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:fmt"
import "core:math"
import mu "vendor:microui"

CONTROL_POINTS :: 32
PATH_DEBUG_SAMPLES :: 96

target_nodes:  [dynamic]world.NodeHandle
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
  mjolnir.run_app({
    title      = "Path Modifier",
    width      = 900,
    height     = 650,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

regenerate_points :: proc() {
  lobes_i := max(1, int(math.round(f32(lobes))))
  for i in 0 ..< CONTROL_POINTS {
    t := f32(i) / f32(CONTROL_POINTS)
    u := t * math.PI * 2.0
    path_buf[i] = {f32(radius) * math.cos(u), f32(height) * math.sin(u * f32(lobes_i)), f32(radius) * math.sin(u)}
  }
}

rebuild_path :: proc(engine: ^mjolnir.Engine) {
  regenerate_points()
  animation.spline_destroy(&spline)
  spline = animation.spline_build_closed(path_buf[:])
  for node_handle, i in target_nodes {
    world.set_path_modifier_params(&engine.world, node_handle, layer_indices[i], path = path_buf[:])
  }
}

apply_runtime_params :: proc(engine: ^mjolnir.Engine) {
  for node_handle, i in target_nodes {
    world.set_path_modifier_params(&engine.world, node_handle, layer_indices[i], offset = f32(offset_val), length = f32(fit_len), speed = 0, loop = true)
  }
}

draw_path_debug :: proc(engine: ^mjolnir.Engine) {
  spline_len := animation.spline_arc_length(spline)
  if spline_len <= 0 do return
  prev := animation.spline_sample_uniform(spline, 0)
  for i in 1 ..= PATH_DEBUG_SAMPLES {
    s := f32(i) / f32(PATH_DEBUG_SAMPLES) * spline_len
    cur := animation.spline_sample_uniform(spline, s)
    mjolnir.debug_segment(engine, prev, cur, color = {1, 0.85, 0.1, 1}, bypass_depth = true)
    prev = cur
  }
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {5, 3, 5}, {0, 0, 0})
  roots := mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
  regenerate_points()
  spline = animation.spline_build_closed(path_buf[:])

  for handle in roots {
    node := world.node(&engine.world, handle) or_continue
    for child in node.children {
      idx, ok := world.add_path_modifier_layer(&engine.world, child, "root", 14,
        path = path_buf[:], offset = f32(offset_val), length = f32(fit_len),
        speed = 0, loop = true, closed = true, weight = 1.0,
      )
      if ok {
        append(&target_nodes, child)
        append(&layer_indices, idx)
      }
    }
  }
  world.spawn_ground(&engine.world, 30.0, position = {0, -3, 0})
  world.spawn_light_point(&engine.world, {0, 10, 0}, {1, 0.9, 0.8, 1}, 15.0, true)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if radius != prev_radius || height != prev_height || lobes != prev_lobes {
    rebuild_path(engine)
    prev_radius = radius; prev_height = height; prev_lobes = lobes
  }
  spline_len := animation.spline_arc_length(spline)
  if auto_play && spline_len > 0 {
    offset_val = mu.Real(math.mod_f32(f32(offset_val) + f32(speed_val) * dt, spline_len))
    if offset_val < 0 do offset_val += mu.Real(spline_len)
  }
  apply_runtime_params(engine)
  draw_path_debug(engine)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
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
