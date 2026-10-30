// Split screen: two players (WASD and the arrows), each smoothly followed by a camera of its own, side by side.
package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

SPEED :: 4

Player :: struct {
  node:     world.NodeHandle,
  position: [3]f32,
  camera:   render.CameraHandle,
  keys:     [4]input.Key,
}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  players:  [2]Player,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Split screen") do return
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
  r := &app.renderer
  mjolnir.spawn(&app.scene, r, render.primitive(r, .QUAD_XZ, .GRAY, cast_shadow = false), scale = 40)
  for i in 0 ..< 36 {
    angle := f32(i) * 2.4
    mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, render.Color(i % 6 + 3)), {math.cos(angle), 0, math.sin(angle)} * f32(5 + i / 2), scale = {0.8, f32(1 + i % 3), 0.8})
  }
  colors := [2]render.Color{.RED, .BLUE}
  keys := [2][4]input.Key{{.A, .D, .W, .S}, {.LEFT, .RIGHT, .UP, .DOWN}}
  for &p, i in app.players {
    p.position = {f32(i) * 4 - 2, 0.5, 0}
    p.node = mjolnir.spawn(&app.scene, r, render.primitive(r, .SPHERE, colors[i]), p.position)
    p.camera = render.camera_create(r, half_size(app), render.make_camera(p.position + {0, 4, 7}, p.position, fov = 1.2))
    p.keys = keys[i]
  }
  return .READY
}

half_size :: proc(app: ^App) -> [2]u32 {
  size := platform.framebuffer_size(&app.platform)
  return {u32(size.x / 2), u32(size.y)}
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
  size := render.window_size(&app.renderer)
  half := half_size(app)
  views: [2]render.OverlayCommand
  for &p, i in app.players {
    move := [3]f32{input.axis(&app.input, p.keys[0], p.keys[1]), 0, input.axis(&app.input, p.keys[2], p.keys[3])}
    p.position += move * SPEED * dt
    world.translate(&app.scene, p.node, p.position)
    if camera, ok := render.camera(&app.renderer, p.camera); ok {
      render.camera_lerp_look_at(camera, p.position + {0, 4, 7}, p.position, geometry.exp_smooth(4, dt))
    }
    render.camera_resize(&app.renderer, p.camera, half)
    image := render.camera_image(&app.renderer, p.camera, .FINAL_IMAGE, previous_frame = true)
    views[i] = {shape = render.OverlayQuad{position = {f32(i) * size.x / 2, 0}, size = {size.x / 2, size.y}, color = 255, texture = image}}
  }
  render.stage_overlay(&app.renderer, views[:])
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
