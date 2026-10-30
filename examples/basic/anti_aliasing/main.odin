// Anti-aliasing: thin bars on a turntable; Space switches the camera's anti-aliasing.
package main

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/font"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

BARS :: 24

App :: struct {
  platform:  platform.Platform,
  scene:     world.World,
  renderer:  render.Renderer,
  input:     input.State,
  font:      font.Font,
  orbit:     render.Orbit,
  turntable: world.NodeHandle,
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
  if !font.init(&app.font, #load("assets/Outfit-Regular.ttf")) do return .FAIL
  r := &app.renderer
  mjolnir.spawn(&app.scene, r, render.primitive(r, .QUAD_XZ, .GRAY, no_shadow = true), scale = 20)
  app.turntable = world.spawn(&app.scene)
  for i in 0 ..< BARS {
    angle := f32(i) / BARS * math.TAU
    position := [3]f32{3 * math.cos(angle), 1.5, 3 * math.sin(angle)}
    mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, .WHITE), position, scale = {0.04, 3, 0.04}, parent = app.turntable)
  }
  for y in ([]f32{0.5, 1.5, 2.5}) {
    mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, .RED), {0, y, 0}, scale = {6.2, 0.03, 0.03}, parent = app.turntable)
    mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, .BLUE), {0, y + 0.5, 0}, scale = {0.03, 0.03, 6.2}, parent = app.turntable)
  }
  mjolnir.spawn(&app.scene, r, render.primitive(r, .SPHERE, .YELLOW), {0, 1.5, 0})
  app.orbit = render.make_orbit({5, 3, 7}, {0, 1.5, 0})
  return .READY
}

shutdown :: proc(app: ^App) {
  font.destroy(&app.font)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  camera := render.main_camera(&app.renderer)
  if input.key_pressed(&app.input, .SPACE) do camera.anti_aliasing = .NONE if camera.anti_aliasing == .FXAA else .FXAA
  mjolnir.orbit_drag(&app.orbit, camera, &app.input)
  world.transform(&app.scene, app.turntable).rotation *= linalg.quaternion_angle_axis(dt * 0.1, linalg.VECTOR3F32_Y_AXIS)
  hud := [?]render.OverlayCommand {
    {shape = render.OverlayText{text = fmt.tprintf("%v (Space)", camera.anti_aliasing), position = {20, 20}, size = 28, color = {255, 255, 255, 255}}},
  }
  render.stage_overlay(&app.renderer, hud[:], &app.font)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
