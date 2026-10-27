// Hierarchical transforms and traversal.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import mu "vendor:microui"

orbit_speed: f32 = 1.0
spin_speed: f32 = 2.0

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  sun:      world.NodeHandle,
  planets:  [3]world.NodeHandle,
  moon:     world.NodeHandle,
  phase:    f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1000, 700, "Scene Graph") do return
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
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  app.orbit = render.make_orbit({0, 10, 4}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  ground := world.spawn(&app.scene, {0, -2, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)

  sun_material := render.material_create(&app.renderer, render.make_material(base_color_factor = {1.0, 0.8, 0.2, 1.0}, emissive_value = 2.0))
  app.sun = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(app.sun.index), render.primitive(&app.renderer, .SPHERE, sun_material))
  world.scale(&app.scene, app.sun, 1.2)

  planet_colors := [3]render.Color{.CYAN, .GREEN, .MAGENTA}
  planet_distances := [3]f32{3.5, 6.0, 9.0}
  for &planet, i in app.planets {
    planet = world.spawn(&app.scene, {planet_distances[i], 0, 0}, parent = app.sun)
    render.attach(&app.renderer, render.SlotHandle(planet.index), render.primitive(&app.renderer, .SPHERE, planet_colors[i]))
    world.scale(&app.scene, planet, 0.5)
  }

  app.moon = world.spawn(&app.scene, {1.5, 0, 0}, parent = app.planets[2])
  render.attach(&app.renderer, render.SlotHandle(app.moon.index), render.primitive(&app.renderer, .CUBE, .WHITE))
  world.scale(&app.scene, app.moon, 0.3)
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
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
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, &app.input)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.phase += dt * orbit_speed
  world.rotate(&app.scene, app.sun, app.phase * 0.3)
  for planet, i in app.planets {
    world.rotate(&app.scene, planet, app.phase * spin_speed * f32(i + 1) * 0.5)
  }
  world.rotate(&app.scene, app.moon, app.phase * 4.0)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Scene Graph", {720, 20, 260, 180}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Hierarchy: sun > planets > moon")
    mu.label(ctx, "Orbit speed")
    mu.slider(ctx, &orbit_speed, 0.0, 4.0)
    mu.label(ctx, "Spin speed")
    mu.slider(ctx, &spin_speed, 0.0, 6.0)
  }
}
