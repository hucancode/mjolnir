// Hierarchical transforms and traversal.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import mu "vendor:microui"

orbit_speed: mu.Real = 1.0
spin_speed: mu.Real = 2.0

App :: struct {
  window:   platform.Platform,
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
  w := &app.window
  if !platform.init(w, 1000, 700, "Scene Graph") do return
  if !render.init(&app.renderer, "Scene Graph", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

  render.camera_look_at(render.main_camera(&app.renderer), {0, 14, 18}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))


  ground := world.spawn(&app.scene, {0, -2, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)

  sun_material := render.material_create(&app.renderer, render.make_material(base_color_factor = {1.0, 0.8, 0.2, 1.0}, emissive_value = 2.0))
  app.sun = world.spawn(&app.scene)
  render.attach(&app.renderer, render.SlotHandle(app.sun.index), render.MeshAttachment{mesh = app.renderer.builtin_meshes[.SPHERE], material = sun_material, cast_shadow = true})
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
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.phase += dt * f32(orbit_speed)
  world.rotate(&app.scene, app.sun, app.phase * 0.3)
  for planet, i in app.planets {
    world.rotate(&app.scene, planet, app.phase * f32(spin_speed) * f32(i + 1) * 0.5)
  }
  world.rotate(&app.scene, app.moon, app.phase * 4.0)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Scene Graph", {720, 20, 260, 240}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Hierarchy: sun > planets > moon")
    mu.label(ctx, "Each planet inherits sun rotation.")
    mu.label(ctx, "Moon inherits outer planet too.")
    mu.label(ctx, "")
    mu.label(ctx, "Orbit speed")
    mu.slider(ctx, &orbit_speed, 0.0, 4.0)
    mu.label(ctx, "Spin speed")
    mu.slider(ctx, &spin_speed, 0.0, 6.0)
  }
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
