package main

import "../../mjolnir"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

fox_handle: mjolnir.NodeHandle
target_cube: mjolnir.NodeHandle

walk_layer:   int = -1
run_layer:    int = -1
survey_layer: int = -1
ik_layer:     int = -1

walk_run_blend: mu.Real = 0.0
auto_blend:     bool    = true
blend_dir:      f32     = 1.0
survey_weight:  mu.Real = 0.0
ik_weight:      mu.Real = 0.0
animate_target: bool    = true
target_x:       mu.Real = 0.0
target_y:       mu.Real = 4.0
target_z:       mu.Real = 5.0
target_radius:  mu.Real = 4.0
target_speed:   mu.Real = 1.0
TRANSITION_DURATION :: f32(1.5)
on_run: bool = false

main :: proc() {
  mjolnir.run_app({
    title      = "Animation Layering",
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {3, 2, 3}, {0, 1, 0})

  roots := mjolnir.load_gltf(engine, "assets/Fox2.glb")
  if len(roots) == 0 {
    log.error("Failed to load Fox2.glb")
    return
  }
  for handle in roots {
    child, has := mjolnir.skinned_mesh(engine, handle)
    if !has do continue
    fox_handle = child

    ok: bool
    walk_layer,   ok = mjolnir.add_animation_layer(engine, child, "Walk", weight = 1.0); if !ok do log.error("Walk add failed")
    run_layer,    ok = mjolnir.add_animation_layer(engine, child, "Run",  weight = 0.0); if !ok do log.error("Run add failed")
    survey_layer, ok = mjolnir.add_animation_layer(engine, child, "Survey", weight = 0.0, speed = 0.5); if !ok do log.warn("Survey not found")
    ik_layer,     ok = mjolnir.add_ik_layer(engine, child, []string{"b_Spine01_02", "b_Spine02_03", "b_Neck_04", "b_Head_05"}, {f32(target_x), f32(target_y), f32(target_z)}, {0, 5, 2.5}, weight = 0.0, space = .WORLD)
    if !ok do log.error("IK add failed")
    log.infof("Layers: walk=%d run=%d survey=%d ik=%d", walk_layer, run_layer, survey_layer, ik_layer)
    break
  }

  target_cube = mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED, position = {f32(target_x), f32(target_y), f32(target_z)}, cast_shadow = false)
  mjolnir.scale(engine, target_cube, 0.25)
  mjolnir.spawn_light_directional(engine, color = {1, 1, 1, 1}, radius = 10.0, cast_shadow = true)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if !mjolnir.valid(engine, fox_handle) do return

  if auto_blend {
    walk_run_blend += mu.Real(blend_dir * dt * 0.5)
    if walk_run_blend >= 1.0 { walk_run_blend = 1.0; blend_dir = -1.0 }
    if walk_run_blend <= 0.0 { walk_run_blend = 0.0; blend_dir =  1.0 }
  }

  if walk_layer >= 0 do mjolnir.set_animation_layer_weight(engine, fox_handle, walk_layer, 1.0 - f32(walk_run_blend))
  if run_layer  >= 0 do mjolnir.set_animation_layer_weight(engine, fox_handle, run_layer,  f32(walk_run_blend))
  if survey_layer >= 0 do mjolnir.set_animation_layer_weight(engine, fox_handle, survey_layer, f32(survey_weight))

  if ik_layer >= 0 {
    mjolnir.set_animation_layer_weight(engine, fox_handle, ik_layer, f32(ik_weight))
    if animate_target {
      t := mjolnir.time_since_start(engine) * f32(target_speed)
      r := f32(target_radius)
      target_x = mu.Real(math.cos(t) * r)
      target_z = mu.Real(math.sin(t) * r)
      target_y = mu.Real(4.0 + math.sin(t * 2.0))
    }
    pos := [3]f32{f32(target_x), f32(target_y), f32(target_z)}
    mjolnir.set_ik_layer_target(engine, fox_handle, ik_layer, pos, {0, 5, 0})
    if mjolnir.valid(engine, target_cube) do mjolnir.translate(engine, target_cube, pos)
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Animation Layering", {480, 20, 320, 490}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Base layer (Walk <-> Run)")
    mu.checkbox(ctx, "Auto blend", &auto_blend)
    mu.label(ctx, fmt.tprintf("Blend: %.2f", walk_run_blend))
    mu.slider(ctx, &walk_run_blend, 0.0, 1.0)
    if .SUBMIT in mu.button(ctx, "Trigger transition") {
      if walk_layer >= 0 && run_layer >= 0 {
        on_run = !on_run
        name := on_run ? "Run" : "Walk"
        from := on_run ? walk_layer : run_layer
        to   := on_run ? run_layer  : walk_layer
        mjolnir.transition_to_animation(engine, fox_handle, name, duration = TRANSITION_DURATION, from_layer = from, to_layer = to)
        auto_blend = false
        walk_run_blend = on_run ? 1.0 : 0.0
      }
    }
    mu.label(ctx, "")
    mu.label(ctx, "Upper body (Survey)")
    mu.label(ctx, fmt.tprintf("Weight: %.2f", survey_weight)); mu.slider(ctx, &survey_weight, 0.0, 1.0)
    mu.label(ctx, "")
    mu.label(ctx, "IK head tracking")
    mu.label(ctx, fmt.tprintf("Weight: %.2f", ik_weight)); mu.slider(ctx, &ik_weight, 0.0, 1.0)
    mu.checkbox(ctx, "Animate target", &animate_target)
    if animate_target {
      mu.label(ctx, fmt.tprintf("Radius: %.2f", target_radius)); mu.slider(ctx, &target_radius, 1.0, 8.0)
      mu.label(ctx, fmt.tprintf("Speed: %.2f", target_speed));   mu.slider(ctx, &target_speed, 0.0, 4.0)
    } else {
      mu.label(ctx, fmt.tprintf("X: %.2f", target_x)); mu.slider(ctx, &target_x, -8.0, 8.0)
      mu.label(ctx, fmt.tprintf("Y: %.2f", target_y)); mu.slider(ctx, &target_y, 0.0, 8.0)
      mu.label(ctx, fmt.tprintf("Z: %.2f", target_z)); mu.slider(ctx, &target_z, -8.0, 8.0)
    }
  }
}
