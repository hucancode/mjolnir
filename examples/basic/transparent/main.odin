// Order-dependent transparency.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"

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
  if !platform.init(&app.platform, 800, 600, "Transparent") do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  app.orbit = render.make_orbit({6, 3, 6}, {0, 1, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false), scale = 6.0)

  red := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.95, 0.15, 0.15, 1}, roughness_value = 0.4))
  sphere_behind_glass := world.spawn(&app.scene, {0, 1, -2})
  render.attach(&app.renderer, sphere_behind_glass, render.primitive(&app.renderer, .SPHERE, red))

  glass_colors := [4][4]f32{
    {0.2, 0.7, 1.0, 0.20},
    {0.2, 1.0, 0.4, 0.40},
    {1.0, 0.7, 0.2, 0.65},
    {1.0, 0.2, 0.7, 0.85},
  }
  for color, i in glass_colors {
    glass := render.material_create(&app.renderer, render.make_material(.TRANSPARENT, base_color_factor = color))
    mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, glass, cast_shadow = false), {f32(i) * 0.6 - 1.0, 1.0, f32(i) * 0.4}, scale = 0.8)
  }

  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
