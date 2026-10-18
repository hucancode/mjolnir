// glTF asset import.
package main

import "core:log"
import "core:math"
import "../../mjolnir"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  duck:     gltf.Model,
  gltf:     gltf.Instance,
  orbit:    render.Orbit,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "GLTF Static") do return
  if !render.init(&app.renderer, "GLTF Static", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  render.camera_look_at(render.main_camera(&app.renderer), {6, 4, 6}, {0, 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1, 0})
  app.duck = gltf.model_create(&app.renderer, #load("../../assets/Duck.glb"))
  app.gltf = gltf.instance_create(&app.duck, &app.scene, &app.renderer)
  light := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light()))
  return .READY
}

shutdown :: proc(app: ^App) {
  gltf.destroy(&app.gltf, &app.scene)
  gltf.destroy(&app.duck, &app.renderer)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  rot := dt * math.PI * 0.5
  for h in app.gltf.roots do world.rotate_by(&app.scene, h, rot)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
