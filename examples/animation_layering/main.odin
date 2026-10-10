package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

scene: mjolnir.GltfScene
fox_handle: world.NodeHandle
rig: ^anim.Rig
animator: anim.Animator
target_cube: world.NodeHandle

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
    sync       = sync,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {3, 2, 3}, {0, 1, 0})

  scene = mjolnir.load_gltf(engine, "assets/Fox2.glb")
  if len(scene.skinned) == 0 {
    log.error("Fox2.glb has no skinned mesh")
    return
  }
  fox_handle = scene.skinned[0].node
  rig = &scene.rigs[scene.skinned[0].rig]
  anim.animator_init(&animator, &rig.skeleton)
  walk_layer,   _ = anim.add_clip_layer(&animator, rig, "Walk", weight = 1.0)
  run_layer,    _ = anim.add_clip_layer(&animator, rig, "Run",  weight = 0.0)
  survey_layer, _ = anim.add_clip_layer(&animator, rig, "Survey", weight = 0.0, speed = 0.5)
  if bones, ok := anim.find_bones(&rig.skeleton, {"b_Spine01_02", "b_Spine02_03", "b_Neck_04", "b_Head_05"}); ok {
    ik_layer, _ = anim.add_ik_layer(&animator, &rig.skeleton, bones, {f32(target_x), f32(target_y), f32(target_z)}, {0, 5, 2.5}, weight = 0.0, space = .WORLD)
  }
  log.infof("Layers: walk=%d run=%d survey=%d ik=%d", walk_layer, run_layer, survey_layer, ik_layer)

  target_cube = mjolnir.spawn_primitive_mesh(engine, .CUBE, .RED, position = {f32(target_x), f32(target_y), f32(target_z)}, cast_shadow = false)
  world.scale(&engine.world, target_cube, 0.25)
  mjolnir.spawn(engine, attachment = render.directional_light_attachment({1, 1, 1, 1}, 10.0, true))
}

sync :: proc(engine: ^mjolnir.Engine) {
  if rig != nil do render.stage_bones(&engine.render, fox_handle.index, animator.palette)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if rig == nil do return

  if auto_blend {
    walk_run_blend += mu.Real(blend_dir * dt * 0.5)
    if walk_run_blend >= 1.0 { walk_run_blend = 1.0; blend_dir = -1.0 }
    if walk_run_blend <= 0.0 { walk_run_blend = 0.0; blend_dir =  1.0 }
  }

  if walk_layer >= 0 do anim.set_layer_weight(&animator, walk_layer, 1.0 - f32(walk_run_blend))
  if run_layer  >= 0 do anim.set_layer_weight(&animator, run_layer,  f32(walk_run_blend))
  if survey_layer >= 0 do anim.set_layer_weight(&animator, survey_layer, f32(survey_weight))

  if ik_layer >= 0 {
    anim.set_layer_weight(&animator, ik_layer, f32(ik_weight))
    if animate_target {
      t := mjolnir.time_since_start(engine) * f32(target_speed)
      r := f32(target_radius)
      target_x = mu.Real(math.cos(t) * r)
      target_z = mu.Real(math.sin(t) * r)
      target_y = mu.Real(4.0 + math.sin(t * 2.0))
    }
    pos := [3]f32{f32(target_x), f32(target_y), f32(target_z)}
    anim.set_ik_target(&animator, ik_layer, pos, {0, 5, 0})
    if world.valid(&engine.world, target_cube) do world.translate(&engine.world, target_cube, pos)
  }
  anim.animator_update(&animator, rig, dt, world.world_matrix(&engine.world, fox_handle))
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
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
        anim.transition_to(&animator, rig, name, duration = TRANSITION_DURATION, from = from, to = to)
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
