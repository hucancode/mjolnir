// Bone-mask layer blending across multiple clips.
package main

import "core:log"
import "core:math"
import mu "vendor:microui"
import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/debugui"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

TRANSITION_DURATION :: f32(1.5)
IK_POLE :: [3]f32{0, 5, 0}

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
  auto_blend:     bool,
  blend_dir:      f32,
  on_run:         bool,
  survey_weight:  mu.Real,
  ik_weight:      mu.Real,
  animate_target: bool,
  target:         [3]mu.Real,
  target_radius:  mu.Real,
  target_speed:   mu.Real,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.auto_blend = true
  app.blend_dir = 1
  app.animate_target = true
  app.target = {0, 4, 5}
  app.target_radius = 4
  app.target_speed = 1
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

  app.fox_model = gltf.model_create(&app.renderer, #load("../../assets/Fox2.glb"))
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
  return {f32(app.target.x), f32(app.target.y), f32(app.target.z)}
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
  if app.animate_target {
    t := app.time * f32(app.target_speed)
    r := f32(app.target_radius)
    app.target = {mu.Real(math.cos(t) * r), mu.Real(4 + math.sin(t * 2)), mu.Real(math.sin(t) * r)}
  }
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
  if app.auto_blend {
    app.walk_run_blend = clamp(app.walk_run_blend + mu.Real(app.blend_dir * dt * 0.5), 0, 1)
    if app.walk_run_blend == 1 do app.blend_dir = -1
    if app.walk_run_blend == 0 do app.blend_dir = 1
    set_walk_run(app, 0)
  }
  anim.layer_fade(&app.animator, app.survey_layer, f32(app.survey_weight))
  anim.layer_fade(&app.animator, app.ik_layer, f32(app.ik_weight))
  if ik, ok := anim.layer_params(&app.animator, app.ik_layer, anim.IKParams); ok {
    ik.target, ik.pole = target_position(app), IK_POLE
  }
}

set_walk_run :: proc(app: ^App, duration: f32) {
  anim.layer_fade(&app.animator, app.walk_layer, 1 - f32(app.walk_run_blend), duration)
  anim.layer_fade(&app.animator, app.run_layer, f32(app.walk_run_blend), duration)
}

cross_fade_walk_run :: proc(app: ^App) {
  app.on_run = !app.on_run
  app.auto_blend = false
  app.walk_run_blend = 1 if app.on_run else 0
  anim.clip_seek(&app.animator, app.run_layer if app.on_run else app.walk_layer, 0)
  set_walk_run(app, TRANSITION_DURATION)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Animation Layering", {480, 20, 320, 490}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Base layer (Walk <-> Run)")
    mu.checkbox(ctx, "Auto blend", &app.auto_blend)
    mu.label(ctx, "Blend")
    if .CHANGE in mu.slider(ctx, &app.walk_run_blend, 0, 1) {
      app.auto_blend = false
      set_walk_run(app, 0)
    }
    if .SUBMIT in mu.button(ctx, "Trigger transition") do cross_fade_walk_run(app)
    mu.label(ctx, "")
    mu.label(ctx, "Upper body (Survey)")
    mu.label(ctx, "Weight"); mu.slider(ctx, &app.survey_weight, 0, 1)
    mu.label(ctx, "")
    mu.label(ctx, "IK head tracking")
    mu.label(ctx, "Weight"); mu.slider(ctx, &app.ik_weight, 0, 1)
    mu.checkbox(ctx, "Animate target", &app.animate_target)
    if app.animate_target {
      mu.label(ctx, "Radius"); mu.slider(ctx, &app.target_radius, 1, 8)
      mu.label(ctx, "Speed"); mu.slider(ctx, &app.target_speed, 0, 4)
    } else {
      mu.label(ctx, "X"); mu.slider(ctx, &app.target.x, -8, 8)
      mu.label(ctx, "Y"); mu.slider(ctx, &app.target.y, 0, 8)
      mu.label(ctx, "Z"); mu.slider(ctx, &app.target.z, -8, 8)
    }
  }
}
