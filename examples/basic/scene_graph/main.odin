// Hierarchical transforms: a sun, its planets and a moon, each spinning its children along.
package main

import "core:log"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

App :: struct {
  platform:    platform.Platform,
  scene:       world.World,
  renderer:    render.Renderer,
  debug:       debugui.Context,
  input:       input.State,
  orbit:       render.Orbit,
  sun:         world.NodeHandle,
  planets:     [3]world.NodeHandle,
  moon:        world.NodeHandle,
  phase:       f32,
  orbit_speed: f32,
  spin_speed:  f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Scene Graph") do return
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
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  app.orbit = render.make_orbit({0, 10, 4}, {0, 0, 0})
  app.orbit_speed = 1
  app.spin_speed = 2

  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, no_shadow = true), {0, -2, 0}, scale = 20.0)

  sun_material := render.material_create(&app.renderer, render.make_material(base_color_factor = {1.0, 0.8, 0.2, 1.0}, emissive_factor = 2.0))
  app.sun = body(app, render.primitive(&app.renderer, .SPHERE, sun_material), {}, 1.2, {})

  planet_colors := [3]render.Color{.CYAN, .GREEN, .MAGENTA}
  planet_distances := [3]f32{4.2, 7.2, 10.8}
  for &planet, i in app.planets {
    planet = body(app, render.primitive(&app.renderer, .SPHERE, planet_colors[i]), {planet_distances[i], 0, 0}, 0.6, app.sun)
  }

  app.moon = body(app, render.primitive(&app.renderer, .CUBE, .WHITE), {0.9, 0, 0}, 0.18, app.planets[2])
  return .READY
}

body :: proc(app: ^App, mesh: render.Attachment, position: [3]f32, size: f32, parent: world.NodeHandle) -> world.NodeHandle {
  node := world.spawn(&app.scene, position, parent = parent)
  mjolnir.spawn(&app.scene, &app.renderer, mesh, scale = size, parent = node)
  return node
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  app.phase += dt * app.orbit_speed
  world.transform(&app.scene, app.sun).rotation = linalg.quaternion_angle_axis(app.phase * 0.3, linalg.VECTOR3F32_Y_AXIS)
  for planet, i in app.planets {
    world.transform(&app.scene, planet).rotation = linalg.quaternion_angle_axis(app.phase * app.spin_speed * f32(i + 1) * 0.5, linalg.VECTOR3F32_Y_AXIS)
  }
  world.transform(&app.scene, app.moon).rotation = linalg.quaternion_angle_axis(app.phase * 4.0, linalg.VECTOR3F32_Y_AXIS)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  if debugui.window(&app.debug, "Scene Graph", {20, 20, 260, 180}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Hierarchy: sun > planets > moon")
    mu.label(ctx, "Orbit speed")
    mu.slider(ctx, &app.orbit_speed, 0.0, 4.0)
    mu.label(ctx, "Spin speed")
    mu.slider(ctx, &app.spin_speed, 0.0, 6.0)
  }
}
