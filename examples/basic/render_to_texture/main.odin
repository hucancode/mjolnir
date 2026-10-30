// A second camera rendered into a texture that a screen in the scene shows; the spinning cube is on a layer only that camera draws.
package main

import "core:log"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

App :: struct {
  platform:        platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  input:           input.State,
  orbit:           render.Orbit,
  time:            f32,
  top_down_camera: render.CameraHandle,
  screen_material: render.MaterialHandle,
  spinner:         world.NodeHandle,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Render To Texture") do return
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
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

spawn_primitive :: proc(app: ^App, shape: render.Primitive, color: render.Color, position: [3]f32, scale_factor: f32 = 1, no_shadow := false) -> world.NodeHandle {
  return mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, shape, color, no_shadow), position, scale = scale_factor)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  app.orbit = render.make_orbit({5, 3, 6}, {0, 1, 0})

  spawn_primitive(app, .QUAD_XZ, .GRAY, {0, 0, 0}, 6.0, no_shadow = true)

  spawn_primitive(app, .CUBE,   .RED,   {-1.5, 0.5, 0})
  spawn_primitive(app, .SPHERE, .GREEN, {0, 0.6, 1.0}, 0.6)
  spawn_primitive(app, .CONE,   .BLUE,  {1.5, 0.5, -0.5})
  spinner := render.primitive(&app.renderer, .CUBE, .YELLOW)
  spinner.layer = 1
  app.spinner = mjolnir.spawn(&app.scene, &app.renderer, spinner, {0, 1.8, 0}, scale = 0.4)
  render.main_camera(&app.renderer).hidden_layers = {1}

  top_down := render.make_camera({0, 8, 0.01}, {0, 0, 0}, far = 100)
  top_down.hidden_layers = {2}
  app.top_down_camera = render.camera_create(&app.renderer, {512, 512}, top_down)
  app.screen_material = render.material_create(&app.renderer, render.make_material())
  screen := render.primitive(&app.renderer, .QUAD_XY, app.screen_material, no_shadow = true)
  screen.layer = 2
  mjolnir.spawn(&app.scene, &app.renderer, screen, {0, 2.5, -3.5}, scale = 3.0)
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  app.time += dt
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  world.transform(&app.scene, app.spinner).rotation = linalg.quaternion_angle_axis(app.time, linalg.VECTOR3F32_Y_AXIS)
  screen := render.material(&app.renderer, app.screen_material)
  screen.albedo_texture = render.camera_image(&app.renderer, app.top_down_camera, .FINAL_IMAGE, previous_frame = true)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
