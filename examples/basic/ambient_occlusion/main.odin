// Ambient occlusion darkening a room's corners and contacts, tuned from a panel.
package main

import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"

App :: struct {
  platform:        platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  input:           input.State,
  orbit:           render.Orbit,
  debug:           debugui.Context,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Ambient Occlusion") do return
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
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

spawn_primitive :: proc(app: ^App, shape: render.Primitive, color: render.Color, position: [3]f32, scale: [3]f32 = {1, 1, 1}) -> world.NodeHandle {
  return mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, shape, color), position, scale)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.renderer.sun.intensity = 0.3
  app.orbit = render.make_orbit({5, 4, 5}, {0, 0.8, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  spawn_primitive(app, .CUBE, .GRAY, {0, -0.05, 0}, {8, 0.1, 8})
  spawn_primitive(app, .CUBE, .GRAY, {0, 2, -4}, {8, 4, 0.1})
  spawn_primitive(app, .CUBE, .GRAY, {-4, 2, 0}, {0.1, 4, 8})

  spawn_primitive(app, .CUBE, .RED, {-3, 0.5, -3})
  spawn_primitive(app, .CUBE, .RED, {-3, 1.5, -3}, 0.8)
  spawn_primitive(app, .CUBE, .GREEN, {-1.5, 0.4, -3.4}, 0.8)
  spawn_primitive(app, .SPHERE, .BLUE, {0.5, 0.5, 0.5}, 0.5)
  spawn_primitive(app, .SPHERE, .YELLOW, {1.4, 0.3, 0.9}, 0.3)
  spawn_primitive(app, .CYLINDER, .WHITE, {-3.4, 1, 1}, {0.4, 1, 0.4})
  spawn_primitive(app, .CONE, .GREEN, {1.5, 0.5, -1.5})
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debug_ui(app)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  ao := &render.main_camera(&app.renderer).ambient_occlusion
  if debugui.window(&app.debug, "Ambient Occlusion", {20, 20, 220, 320}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Enabled", &ao.enabled)
    mu.label(ctx, "Radius")
    mu.slider(ctx, &ao.radius, 0.05, 3.0)
    mu.label(ctx, "Intensity")
    mu.slider(ctx, &ao.intensity, 0.0, 4.0)
    mu.label(ctx, "IBL intensity")
    mu.slider(ctx, &app.renderer.ibl_intensity, 0.0, 2.0)
    mu.label(ctx, "Sun intensity")
    mu.slider(ctx, &app.renderer.sun.intensity, 0.0, 5.0)
    if .SUBMIT in mu.button(ctx, "Reset") do ao^ = render.DEFAULT_AMBIENT_OCCLUSION
  }
}
