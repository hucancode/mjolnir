// Camera shake and smooth follow: the camera trails a moving ball; Space hits it, shaking the camera by a trauma that wears off.
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

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  ball:     world.NodeHandle,
  eye:      [3]f32,
  trauma:   f32,
  time:     f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Camera shake") do return
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
  mjolnir.spawn(&app.scene, r, render.primitive(r, .QUAD_XZ, .GRAY, no_shadow = true), scale = 30)
  for x in -3 ..= 3 do for z in -3 ..= 3 {
    if (x + z) % 2 == 0 do mjolnir.spawn(&app.scene, r, render.primitive(r, .CUBE, .WHITE), {f32(x) * 3, 0.25, f32(z) * 3}, scale = 0.5)
  }
  app.ball = mjolnir.spawn(&app.scene, r, render.primitive(r, .SPHERE, .ORANGE), {4, 0.5, 0})
  app.eye = {4, 4, 7}
  render.camera_look_at(render.main_camera(r), app.eye, {4, 0.5, 0})
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
  app.time += dt
  t := app.time
  if input.key_pressed(&app.input, .SPACE) do app.trauma = min(app.trauma + 0.5, 1)
  app.trauma = max(app.trauma - dt, 0)
  target := [3]f32{4 * math.cos(t * 0.6), 0.5, 4 * math.sin(t * 0.6)}
  world.transform(&app.scene, app.ball).position = target
  app.eye = linalg.lerp(app.eye, target + {0, 4, 7}, geometry.exp_smooth(3, dt))
  shake := app.trauma * app.trauma
  offset := shake * 0.3 * [3]f32{math.sin(t * 37), math.sin(t * 43 + 1), math.sin(t * 29 + 2)}
  camera := render.main_camera(&app.renderer)
  render.camera_look_at(camera, app.eye + offset, target)
  camera.rotation *= linalg.quaternion_angle_axis(shake * 0.08 * math.sin(t * 31), linalg.VECTOR3F32_Z_AXIS)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
