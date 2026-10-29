// glTF import: a static model, a skinned one playing its clip, and one cross-fading between clips.
package main

import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/debugui"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

FADE_SECONDS :: f32(0.4)
AUTO_SWITCH_SECONDS :: f32(3)

App :: struct {
  platform:    platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  debug:       debugui.Context,
  input:       input.State,
  orbit:       render.Orbit,
  duck_model:  gltf.Model,
  duck:        gltf.Instance,
  man_model:   gltf.Model,
  man:         gltf.Instance,
  fox_model:   gltf.Model,
  fox:         gltf.Instance,
  fox_rig:     gltf.RigHandle,
  clip:        int,
  playing:     animation.LayerHandle,
  fading:      animation.LayerHandle,
  speed:       f32,
  auto_switch: bool,
  since:       f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.speed = 1
  app.auto_switch = true
  if !platform.init(&app.platform, 1280, 720, "GLTF") do return
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
  gltf.destroy(&app.man, &app.scene, &app.renderer)
  gltf.destroy(&app.man_model, &app.renderer)
  gltf.destroy(&app.duck, &app.scene, &app.renderer)
  gltf.destroy(&app.duck_model, &app.renderer)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 1.6, 3.6}, {0, 0.6, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false), scale = 6.0)

  app.duck_model = gltf.model_create(&app.renderer, #load("assets/Duck.glb"))
  duck_root := world.spawn(&app.scene, {-2, 0, 0})
  app.duck = gltf.instance_create(&app.duck_model, &app.scene, &app.renderer, duck_root)

  app.man_model = gltf.model_create(&app.renderer, #load("assets/CesiumMan.glb"))
  man_root := world.spawn(&app.scene, {0, 0, 0})
  app.man = gltf.instance_create(&app.man_model, &app.scene, &app.renderer, man_root)
  for &a, i in app.man.animators do animation.play(&a, &app.man_model.rigs[i], "Anim_0")

  app.fox_model = gltf.model_create(&app.renderer, #load("assets/Fox2.glb"))
  fox_root := world.spawn(&app.scene, {2, 0, 0})
  app.fox = gltf.instance_create(&app.fox_model, &app.scene, &app.renderer, fox_root)
  if len(app.fox.skinned) == 0 {
    log.error("Fox2.glb has no skinned mesh")
    return .FAIL
  }
  app.fox_rig = app.fox.skinned[0].rig
  play_clip(app, 0)
  return .READY
}

play_clip :: proc(app: ^App, clip: int) {
  rig, animator := &app.fox_model.rigs[app.fox_rig], &app.fox.animators[app.fox_rig]
  animation.destroy(animator, app.fading)
  animation.layer_fade(animator, app.playing, 0, FADE_SECONDS)
  app.fading = app.playing
  params := animation.ClipParams{clip = animation.ClipHandle(clip), speed = app.speed}
  app.playing = animation.layer_create(animator, rig, params, weight = 0)
  animation.layer_fade(animator, app.playing, 1, FADE_SECONDS)
  app.clip = clip
  app.since = 0
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)

  for h in app.duck.roots do world.rotate_by(&app.scene, h, dt * math.PI * 0.25)
  app.since += dt
  if app.auto_switch && app.since >= AUTO_SWITCH_SECONDS {
    play_clip(app, (app.clip + 1) % len(app.fox_model.rigs[app.fox_rig].clips))
  }
  animator := &app.fox.animators[app.fox_rig]
  if params, ok := animation.layer_params(animator, app.playing, animation.ClipParams); ok do params.speed = app.speed

  mjolnir.update(&app.scene, &app.renderer, dt)
  gltf.animate(&app.man, &app.man_model, &app.scene, &app.renderer, dt)
  gltf.animate(&app.fox, &app.fox_model, &app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Fox", {20, 20, 220, 200}) {
    mu.layout_row(ctx, {-1}, 0)
    for clip, i in app.fox_model.rigs[app.fox_rig].clips {
      label := fmt.tprintf("%s%s", "> " if i == app.clip else "", clip.name)
      if .SUBMIT in mu.button(ctx, label) {
        app.auto_switch = false
        if i != app.clip do play_clip(app, i)
      }
    }
    mu.checkbox(ctx, "Auto switch", &app.auto_switch)
    mu.label(ctx, "Speed")
    mu.slider(ctx, &app.speed, 0, 2)
  }
}
