// Order-dependent transparency.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "Transparent") do return
  if !render.init(&app.renderer, "Transparent", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  render.camera_look_at(render.main_camera(&app.renderer), {6, 3, 6}, {0, 1, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 1, 0})

  ground := world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 6.0)

  red := render.material_create(&app.renderer, render.make_material(base_color_factor = {0.95, 0.15, 0.15, 1}, roughness_value = 0.4))
  sphere_behind_glass := world.spawn(&app.scene, {0, 1, -2})
  render.attach(&app.renderer, render.SlotHandle(sphere_behind_glass.index), render.primitive(&app.renderer, .SPHERE, red))

  glass_colors := [4][4]f32{
    {0.2, 0.7, 1.0, 0.20},
    {0.2, 1.0, 0.4, 0.40},
    {1.0, 0.7, 0.2, 0.65},
    {1.0, 0.2, 0.7, 0.85},
  }
  for color, i in glass_colors {
    glass := render.material_create(&app.renderer, render.make_material(.TRANSPARENT, base_color_factor = color))
    slab := world.spawn(&app.scene, {f32(i) * 0.6 - 1.0, 1.0, f32(i) * 0.4})
    render.attach(&app.renderer, render.SlotHandle(slab.index), render.primitive(&app.renderer, .CUBE, glass, cast_shadow = false))
    world.scale(&app.scene, slab, 0.8)
  }

  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
