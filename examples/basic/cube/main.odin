// Hello world!
package main

import "core:log"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Cube") do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .RED))
  app.orbit = render.make_orbit({3, 2, 3}, {0, 0, 0})
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
