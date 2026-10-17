// Bone-mask layer blending across multiple clips.
package main

import "core:fmt"
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

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  time:     f32,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

fox_scene: gltf.Scene
fox_handle: world.NodeHandle
rig: ^anim.Rig
animator: anim.Animator
target_cube: world.NodeHandle

walk_layer:   Maybe(anim.LayerHandle)
run_layer:    Maybe(anim.LayerHandle)
survey_layer: Maybe(anim.LayerHandle)
ik_layer:     Maybe(anim.LayerHandle)

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
  context.logger = log.create_console_logger()
  app := new(App)
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
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
  gltf.destroy(&fox_scene)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {3, 2, 3}, {0, 1, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))

  fox_scene = gltf.scene_create(&app.scene, &app.renderer, #load("../../assets/Fox2.glb"))
  if len(fox_scene.skinned) == 0 {
    log.error("Fox2.glb has no skinned mesh")
    return true
  }
  fox_handle = fox_scene.skinned[0].node
  rig = &fox_scene.rigs[fox_scene.skinned[0].rig]
  anim.animator_init(&animator, rig)
  if clip, ok := anim.find_clip(rig, "Walk"); ok {
    if l, ok := anim.layer_create(&animator, rig, anim.ClipParams{clip = clip, speed = 1}); ok do walk_layer = l
  }
  if clip, ok := anim.find_clip(rig, "Run"); ok {
    if l, ok := anim.layer_create(&animator, rig, anim.ClipParams{clip = clip, speed = 1}, weight = 0); ok do run_layer = l
  }
  // Survey drives only the spine and everything above it; legs keep walking.
  if clip, ok := anim.find_clip(rig, "Survey"); ok {
    upper := anim.bone_subtree(&rig.skeleton, "b_Spine01_02", context.temp_allocator)
    if l, ok := anim.layer_create(&animator, rig, anim.ClipParams{clip = clip, speed = 0.5}, upper, weight = 0); ok do survey_layer = l
  }
  if bones, ok := anim.find_bones(&rig.skeleton, {"b_Spine01_02", "b_Spine02_03", "b_Neck_04", "b_Head_05"}, context.temp_allocator); ok {
    ik := anim.IKParams{target = {f32(target_x), f32(target_y), f32(target_z)}, pole = {0, 5, 2.5}, pole_weight = 1, space = .WORLD}
    if l, ok := anim.layer_create(&animator, rig, ik, bones, weight = 0); ok do ik_layer = l
  }
  log.infof("Layers: walk=%v run=%v survey=%v ik=%v", walk_layer, run_layer, survey_layer, ik_layer)

  target_cube = world.spawn(&app.scene, {f32(target_x), f32(target_y), f32(target_z)})
  render.attach(&app.renderer, render.SlotHandle(target_cube.index), render.primitive(&app.renderer, .CUBE, .RED, cast_shadow = false))
  world.scale(&app.scene, target_cube, 0.25)
  light := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light({1, 1, 1, 1}, 10.0, true)))
  return true
}

update :: proc(app: ^App, dt: f32) {
  app.time += dt
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
  if rig != nil do animate(app, dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  if rig != nil do render.stage_bones(&app.renderer, render.SlotHandle(fox_handle.index), animator.palette)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

animate :: proc(app: ^App, dt: f32) {

  if auto_blend {
    walk_run_blend += mu.Real(blend_dir * dt * 0.5)
    if walk_run_blend >= 1.0 { walk_run_blend = 1.0; blend_dir = -1.0 }
    if walk_run_blend <= 0.0 { walk_run_blend = 0.0; blend_dir =  1.0 }
    set_walk_run(0)
  }
  if l, ok := survey_layer.?; ok do anim.layer_fade(&animator, l, f32(survey_weight))

  if ik, ok := ik_layer.?; ok {
    anim.layer_fade(&animator, ik, f32(ik_weight))
    if animate_target {
      t := app.time * f32(target_speed)
      r := f32(target_radius)
      target_x = mu.Real(math.cos(t) * r)
      target_z = mu.Real(math.sin(t) * r)
      target_y = mu.Real(4.0 + math.sin(t * 2.0))
    }
    pos := [3]f32{f32(target_x), f32(target_y), f32(target_z)}
    if p, ok := anim.layer_params(&animator, ik, anim.IKParams); ok do p.target, p.pole = pos, {0, 5, 0}
    if _, ok := world.node(&app.scene, target_cube); ok do world.translate(&app.scene, target_cube, pos)
  }
  anim.animator_update(&animator, rig, dt, world.world_matrix(&app.scene, fox_handle))
}

// Weigh walk against run by walk_run_blend, fading over `duration` seconds.
set_walk_run :: proc(duration: f32) {
  if l, ok := walk_layer.?; ok do anim.layer_fade(&animator, l, 1.0 - f32(walk_run_blend), duration)
  if l, ok := run_layer.?; ok do anim.layer_fade(&animator, l, f32(walk_run_blend), duration)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Animation Layering", {480, 20, 320, 490}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Base layer (Walk <-> Run)")
    mu.checkbox(ctx, "Auto blend", &auto_blend)
    mu.label(ctx, fmt.tprintf("Blend: %.2f", walk_run_blend))
    if .CHANGE in mu.slider(ctx, &walk_run_blend, 0.0, 1.0) {
      auto_blend = false
      set_walk_run(0)
    }
    if .SUBMIT in mu.button(ctx, "Trigger transition") {
      // cross-fade: one layer fades out while the other fades in from its start
      on_run = !on_run
      auto_blend = false
      walk_run_blend = on_run ? 1.0 : 0.0
      if l, ok := (run_layer if on_run else walk_layer).?; ok do anim.clip_seek(&animator, l, 0)
      set_walk_run(TRANSITION_DURATION)
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
