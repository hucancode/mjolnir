// Anti-aliasing: one scene through two low-resolution cameras magnified side by side, the left one with an FXAA post effect tuned by the panel.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"
import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

BARS :: 24
PIXEL :: 4

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  input:     input.State,
  debug:     debugui.Context,
  orbit:     render.Orbit,
  turntable: world.NodeHandle,
  views:     [2]render.CameraHandle,
  fxaa:      render.FXAAEffect,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Anti-aliasing") do return
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
  r := &app.renderer
  mjolnir.spawn(&app.scene, r, render.primitive(r, .QUAD_XZ, .GRAY, no_shadow = true), scale = 20)
  app.turntable = world.spawn(&app.scene)
  for i in 0 ..< BARS {
    angle := f32(i) / BARS * math.TAU
    position := [3]f32{3 * math.cos(angle), 1.5, 3 * math.sin(angle)}
    mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, .WHITE), position, scale = {0.06, 3, 0.06}, parent = app.turntable)
  }
  for y in ([]f32{0.5, 1.5, 2.5}) {
    mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, .RED), {0, y, 0}, scale = {6.2, 0.06, 0.06}, parent = app.turntable)
    mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, .BLUE), {0, y + 0.5, 0}, scale = {0.06, 0.06, 6.2}, parent = app.turntable)
  }
  mjolnir.spawn(&app.scene, r, render.primitive(r, .SPHERE, .YELLOW), {0, 1.5, 0})
  app.orbit = render.make_orbit({5, 3, 7}, {0, 1.5, 0})
  for &view in app.views do view = render.camera_create(r, view_size(app), render.make_camera({5, 3, 7}, {0, 1.5, 0}))
  app.fxaa = render.DEFAULT_FXAA
  return .READY
}

view_size :: proc(app: ^App) -> [2]u32 {
  size := platform.framebuffer_size(&app.platform)
  return {u32(size.x / 2 / PIXEL), u32(size.y / PIXEL)}
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
  size := render.window_size(&app.renderer)
  quads: [2]render.OverlayCommand
  for view, i in app.views {
    render.camera_resize(&app.renderer, view, view_size(app))
    image := render.camera_image(&app.renderer, view, .FINAL_IMAGE, previous_frame = true)
    quads[i] = {shape = render.OverlayQuad{position = {f32(i) * size.x / 2, 0}, size = {size.x / 2, size.y}, color = 255, texture = image}}
  }
  render.stage_overlay(&app.renderer, quads[:])
  debug_ui(app)
  main_camera := render.main_camera(&app.renderer)
  mjolnir.orbit_drag(&app.orbit, main_camera, &app.input)
  for view in app.views {
    camera := render.camera(&app.renderer, view) or_continue
    camera.position, camera.rotation = main_camera.position, main_camera.rotation
  }
  render.camera(&app.renderer, app.views[0]).effects[0] = render.make_effect(app.fxaa)
  world.transform(&app.scene, app.turntable).rotation *= linalg.quaternion_angle_axis(dt * 0.1, linalg.VECTOR3F32_Y_AXIS)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug, &app.input, &app.renderer)
  defer debugui.end(&app.debug, &app.renderer)
  fxaa := &app.fxaa
  if debugui.window(&app.debug, "Left: FXAA | Right: off", {20, 430, 240, 260}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Edge threshold")
    mu.slider(ctx, &fxaa.edge_threshold, 0.063, 0.333)
    mu.label(ctx, "Edge threshold min")
    mu.slider(ctx, &fxaa.edge_threshold_min, 0.0312, 0.25)
    mu.label(ctx, "Subpixel")
    mu.slider(ctx, &fxaa.subpixel, 0.0, 1.0)
    steps := f32(fxaa.search_steps)
    mu.label(ctx, "Search steps")
    mu.slider(ctx, &steps, 1, render.MAX_FXAA_SEARCH_STEPS, 1, "%.0f")
    fxaa.search_steps = u32(steps)
  }
}
