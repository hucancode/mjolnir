// Skinned glTF playback.
package main

import "core:log"
import "core:math"
import "mjolnir"
import "mjolnir/animation"
import "mjolnir/gltf"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  model:    gltf.Model,
  gltf:     gltf.Instance,
  orbit:    render.Orbit,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 800, 600, "GLTF Animation") do return
  if !render.init(&app.renderer, app.platform.window) do return
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
  gltf.destroy(&app.gltf, &app.scene)
  gltf.destroy(&app.model, &app.renderer)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  app.orbit = render.make_orbit({1.5, 1.5, 1.5}, {0, 1, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.model = gltf.model_create(&app.renderer, #load("assets/CesiumMan.glb"))
  app.gltf = gltf.instance_create(&app.model, &app.scene, &app.renderer)
  for &a, i in app.gltf.animators do animation.play(&a, &app.model.rigs[i], "Anim_0")
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  render.orbit_drag(&app.orbit, &app.input)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  rot := dt * math.PI * 0.05
  for h in app.gltf.roots do world.rotate_by(&app.scene, h, rot)
  world.update(&app.scene)
  gltf.animate(&app.gltf, &app.model, &app.scene, &app.renderer, dt)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}
