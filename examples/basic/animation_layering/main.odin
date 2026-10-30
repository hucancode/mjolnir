// Bone-mask layer blending across multiple clips.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/debugui"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

IK_POLE :: [3]f32{0, 5, 0}
TARGET_RADIUS :: f32(4)

App :: struct {
  platform:       platform.Platform,
  scene:          world.World,
  renderer:       render.Renderer,
  input:          input.State,
  debug:          debugui.Context,
  orbit:          render.Orbit,
  time:           f32,
  fox_model:      gltf.Model,
  fox:            gltf.Instance,
  rig:            gltf.RigHandle,
  target_cube:    world.NodeHandle,
  walk_layer:     animation.LayerHandle,
  run_layer:      animation.LayerHandle,
  survey_layer:   animation.LayerHandle,
  ik_layer:       animation.LayerHandle,
  walk_run_blend: f32,
  auto_mix:       bool,
  survey_weight:  f32,
  ik_weight:      f32,
  target:         [3]f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.walk_run_blend = 0.5
  app.auto_mix = true
  app.target = {0, 4, 5}
  if !platform.init(&app.platform, 1280, 720, "Animation Layering") do return
  if !render.init(&app.renderer, app.platform.window) do return
  if !world.init(&app.scene) do return
  mjolnir.run(
    mjolnir.Loop(App) {
      app = app,
      setup = setup,
      shutdown = shutdown,
      update = update,
      render = draw,
    },
  )
}

shutdown :: proc(app: ^App) {
  gltf.destroy(&app.fox, &app.scene, &app.renderer)
  gltf.destroy(&app.fox_model, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({3, 2, 3}, {0, 1, 0})

  app.target_cube = mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .RED, no_shadow = true), app.target, scale = 0.25)

  app.fox_model = gltf.model_create(&app.renderer, #load("assets/Fox2.glb"))
  app.fox = gltf.instance_create(&app.fox_model, &app.scene, &app.renderer)
  if len(app.fox.skinned) == 0 {
    log.error("Fox2.glb has no skinned mesh")
    return .FAIL
  }
  app.rig = app.fox.skinned[0].rig
  rig, animator := &app.fox_model.rigs[app.rig], &app.fox.animators[app.rig]
  app.walk_layer = clip_layer(app, "Walk", 1, weight = 1)
  app.run_layer = clip_layer(app, "Run", 1)
  app.survey_layer = clip_layer(app, "Survey", 0.5, animation.bone_subtree(&rig.skeleton, "b_Spine01_02", context.temp_allocator))
  if neck, ok := animation.bones_find(&rig.skeleton, {"b_Spine01_02", "b_Spine02_03", "b_Neck_04", "b_Head_05"}, context.temp_allocator); ok {
    ik := animation.IKParams{target = app.target, pole = IK_POLE, pole_weight = 1, space = .WORLD}
    app.ik_layer = animation.layer_create(animator, rig, ik, neck, weight = 0)
  }
  set_walk_run(app)
  return .READY
}

clip_layer :: proc(app: ^App, name: string, speed: f32, bones: []u32 = nil, weight: f32 = 0) -> animation.LayerHandle {
  rig := &app.fox_model.rigs[app.rig]
  clip, found := animation.clip_find(rig, name)
  if !found do return {}
  return animation.layer_create(&app.fox.animators[app.rig], rig, animation.ClipParams{clip = clip, speed = speed}, bones, weight)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  app.time += dt
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  t := app.time
  app.target = {math.cos(t) * TARGET_RADIUS, 4 + math.sin(t * 2), math.sin(t) * TARGET_RADIUS}
  world.transform(&app.scene, app.target_cube).position = app.target
  blend_layers(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
  gltf.animate(&app.fox, &app.fox_model, &app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

blend_layers :: proc(app: ^App) {
  if app.auto_mix {
    app.survey_weight = 0.5 + 0.5 * math.sin(app.time * 0.7)
    app.ik_weight = 0.5 + 0.5 * math.sin(app.time * 0.45 + 2)
  }
  animator := &app.fox.animators[app.rig]
  animation.layer_fade(animator, app.survey_layer, app.survey_weight)
  animation.layer_fade(animator, app.ik_layer, app.ik_weight)
  if ik, ok := animation.layer_params(animator, app.ik_layer, animation.IKParams); ok {
    ik.target, ik.pole = app.target, IK_POLE
  }
}

set_walk_run :: proc(app: ^App) {
  animator := &app.fox.animators[app.rig]
  animation.layer_fade(animator, app.walk_layer, 1 - app.walk_run_blend)
  animation.layer_fade(animator, app.run_layer, app.walk_run_blend)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Animation", {20, 20, 260, 220}) {
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
