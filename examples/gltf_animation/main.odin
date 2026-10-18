// Skinned glTF playback.
package main

import "core:log"
import "core:math"
import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

App :: struct {
  window:    platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  input:     input.State,
  model:     gltf.Model,
  gltf:      gltf.Instance,
  animators: [dynamic]anim.Animator,
  orbit:     render.Orbit,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "GLTF Animation") do return
  if !render.init(&app.renderer, "GLTF Animation", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  for &a in app.animators do anim.destroy(&a)
  delete(app.animators)
  gltf.destroy(&app.gltf, &app.scene)
  gltf.destroy(&app.model, &app.renderer)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  render.camera_look_at(render.main_camera(&app.renderer), {1.5, 1.5, 1.5}, {0, 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1, 0})
  app.model = gltf.model_create(&app.renderer, #load("../../assets/CesiumMan.glb"))
  app.gltf = gltf.instance_create(&app.model, &app.scene, &app.renderer)
  for s in app.gltf.skinned {
    rig := &app.model.rigs[s.rig]
    a: anim.Animator
    anim.animator_init(&a, rig)
    anim.play(&a, rig, "Anim_0")
    append(&app.animators, a)
  }
  light := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light()))
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  rot := dt * math.PI * 0.05
  for h in app.gltf.roots do world.rotate_by(&app.scene, h, rot)
  for s, i in app.gltf.skinned do anim.animator_update(&app.animators[i], &app.model.rigs[s.rig], dt)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  for s, i in app.gltf.skinned do render.stage_bones(&app.renderer, render.SlotHandle(s.node.index), app.animators[i].palette)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
