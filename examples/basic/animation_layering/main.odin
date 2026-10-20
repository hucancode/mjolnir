// Bone-mask layer blending across multiple clips.
package main

import "core:log"
import "core:math"
import mu "vendor:microui"
import "mjolnir"
import anim "mjolnir/animation"
import "mjolnir/debugui"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

IK_POLE :: [3]f32{0, 5, 0}
TARGET_RADIUS :: f32(4)

App :: struct {
  window:         platform.Platform,
  scene:          world.World,
  renderer:       render.Renderer,
  debug:          debugui.Context,
  input:          input.State,
  orbit:          render.Orbit,
  time:           f32,
  fox_model:      gltf.Model,
  fox:            gltf.Instance,
  fox_node:       world.NodeHandle,
  rig:            ^anim.Rig,
  animator:       anim.Animator,
  target_cube:    world.NodeHandle,
  walk_layer:     anim.LayerHandle,
  run_layer:      anim.LayerHandle,
  survey_layer:   anim.LayerHandle,
  ik_layer:       anim.LayerHandle,
  walk_run_blend: mu.Real,
  auto_mix:       bool,
  blend_dir:      f32,
  survey_weight:  mu.Real,
  ik_weight:      mu.Real,
  target:         [3]f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.walk_run_blend = 0.5
  app.auto_mix = true
  app.blend_dir = 1
  app.target = {0, 4, 5}
  w := &app.window
  if !platform.init(w, 800, 600, "Animation Layering") do return
  if !render.init(&app.renderer, "Animation Layering", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  anim.destroy(&app.animator)
  gltf.destroy(&app.fox, &app.scene)
  gltf.destroy(&app.fox_model, &app.renderer)
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
  if !debugui.init(&app.debug, &app.renderer, {800, 600}) do return .FAIL
  render.camera_look_at(render.main_camera(&app.renderer), {3, 2, 3}, {0, 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1, 0})

  app.target_cube = world.spawn(&app.scene, target_position(app))
  render.attach(&app.renderer, render.SlotHandle(app.target_cube.index), render.primitive(&app.renderer, .CUBE, .RED, cast_shadow = false))
  world.scale(&app.scene, app.target_cube, 0.25)

  app.fox_model = gltf.model_create(&app.renderer, #load("assets/Fox2.glb"))
  app.fox = gltf.instance_create(&app.fox_model, &app.scene, &app.renderer)
  if len(app.fox.skinned) == 0 {
    log.error("Fox2.glb has no skinned mesh")
    return .FAIL
  }
  app.fox_node = app.fox.skinned[0].node
  app.rig = &app.fox_model.rigs[app.fox.skinned[0].rig]
  anim.animator_init(&app.animator, app.rig)
  app.walk_layer = clip_layer(app, "Walk", 1, weight = 1)
  app.run_layer = clip_layer(app, "Run", 1)
  app.survey_layer = clip_layer(app, "Survey", 0.5, anim.bone_subtree(&app.rig.skeleton, "b_Spine01_02", context.temp_allocator))
  if neck, ok := anim.bones_find(&app.rig.skeleton, {"b_Spine01_02", "b_Spine02_03", "b_Neck_04", "b_Head_05"}, context.temp_allocator); ok {
    ik := anim.IKParams{target = target_position(app), pole = IK_POLE, pole_weight = 1, space = .WORLD}
    app.ik_layer = anim.layer_create(&app.animator, app.rig, ik, neck, weight = 0)
  }
  return .READY
}

clip_layer :: proc(app: ^App, name: string, speed: f32, bones: []u32 = nil, weight: f32 = 0) -> anim.LayerHandle {
  clip, found := anim.clip_find(app.rig, name)
  if !found do return {}
  return anim.layer_create(&app.animator, app.rig, anim.ClipParams{clip = clip, speed = speed}, bones, weight)
}

target_position :: proc(app: ^App) -> [3]f32 {
  return app.target
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  app.time += dt
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  t := app.time
  app.target = {math.cos(t) * TARGET_RADIUS, 4 + math.sin(t * 2), math.sin(t) * TARGET_RADIUS}
  world.translate(&app.scene, app.target_cube, target_position(app))
  if app.rig != nil do animate(app, dt)
  world.update(&app.scene)
  if app.rig != nil do anim.animator_update(&app.animator, app.rig, dt, world.world_matrix(&app.scene, app.fox_node))
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  if app.rig != nil do for s in app.fox.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), app.animator.palette)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

animate :: proc(app: ^App, dt: f32) {
  if app.auto_mix {
    app.survey_weight = mu.Real(0.5 + 0.5 * math.sin(app.time * 0.7))
    app.ik_weight = mu.Real(0.5 + 0.5 * math.sin(app.time * 0.45 + 2))
  }
  anim.layer_fade(&app.animator, app.survey_layer, f32(app.survey_weight))
  anim.layer_fade(&app.animator, app.ik_layer, f32(app.ik_weight))
  if ik, ok := anim.layer_params(&app.animator, app.ik_layer, anim.IKParams); ok {
    ik.target, ik.pole = target_position(app), IK_POLE
  }
}

set_walk_run :: proc(app: ^App) {
  anim.layer_fade(&app.animator, app.walk_layer, 1 - f32(app.walk_run_blend))
  anim.layer_fade(&app.animator, app.run_layer, f32(app.walk_run_blend))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Animation", {20, 20, 260, 220}, {}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Walk <-> Run")
    if .CHANGE in mu.slider(ctx, &app.walk_run_blend, 0, 1) {
      set_walk_run(app)
    }
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Auto mix", &app.auto_mix)
    mu.label(ctx, "Survey")
    if .CHANGE in mu.slider(ctx, &app.survey_weight, 0, 1) do app.auto_mix = false
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Head tracking")
    if .CHANGE in mu.slider(ctx, &app.ik_weight, 0, 1) do app.auto_mix = false
  }
}
