package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:fmt"
import "core:math"
import mu "vendor:microui"

CONTROL_POINTS :: 32
PATH_DEBUG_SAMPLES :: 96

scene:         mjolnir.GltfScene
// one animator (and its path layer) per scene.skinned entry
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
  defer mjolnir.gltf_scene_destroy(&scene)
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
  for &a, i in animators do animation.set_path_params(&a, layer_indices[i], path = path_buf[:])
}

apply_runtime_params :: proc(engine: ^mjolnir.Engine) {
  for &a, i in animators {
    animation.set_path_params(&a, layer_indices[i], offset = f32(offset_val), length = f32(fit_len), speed = 0, loop = true)
  }
}

draw_path_debug :: proc(engine: ^mjolnir.Engine) {
  spline_len := animation.spline_arc_length(spline)
  if spline_len <= 0 do return
  prev := animation.spline_sample_uniform(spline, 0)
  for i in 1 ..= PATH_DEBUG_SAMPLES {
    s := f32(i) / f32(PATH_DEBUG_SAMPLES) * spline_len
    cur := animation.spline_sample_uniform(spline, s)
    render.debug_segment(&engine.render, prev, cur, color = {1, 0.85, 0.1, 1}, bypass_depth = true)
    prev = cur
  }
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {5, 3, 5}, {0, 0, 0})
  scene = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
  regenerate_points()
  spline = animation.spline_build_closed(path_buf[:])

  for s in scene.skinned {
    rig := &scene.rigs[s.rig]
    a: animation.Animator
    animation.animator_init(&a, rig)
    idx, _ := animation.add_path_layer(&a, rig, "root", 14,
      path = path_buf[:], offset = f32(offset_val), length = f32(fit_len),
      speed = 0, loop = true, closed = true, weight = 1.0,
    )
    append(&animators, a)
    append(&layer_indices, idx)
  }
  mjolnir.spawn_ground(engine, 30.0, position = {0, -3, 0})
  mjolnir.spawn(engine, {0, 10, 0}, render.point_light_attachment({1, 0.9, 0.8, 1}, 15.0, true))
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
  for s, i in scene.skinned do animation.animator_update(&animators[i], &scene.rigs[s.rig], dt)
  draw_path_debug(engine)
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
  for s, i in scene.skinned do render.stage_bones(&engine.render, s.node.index, animators[i].palette)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
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
