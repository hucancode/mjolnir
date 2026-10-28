// Secondary camera rendered into a bindless texture.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

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

spawn_primitive :: proc(app: ^App, shape: render.Primitive, color: render.Color, position: [3]f32, scale_factor: f32 = 1, cast_shadow := true) -> world.NodeHandle {
  return mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, shape, color, cast_shadow), position, scale = scale_factor)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  app.orbit = render.make_orbit({5, 3, 6}, {0, 1, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  spawn_primitive(app, .QUAD_XZ, .GRAY, {0, 0, 0}, 6.0, cast_shadow = false)

  spawn_primitive(app, .CUBE,   .RED,   {-1.5, 0.5, 0})
  spawn_primitive(app, .SPHERE, .GREEN, {0, 0.6, 1.0}, 0.6)
  spawn_primitive(app, .CONE,   .BLUE,  {1.5, 0.5, -0.5})
  app.spinner = spawn_primitive(app, .CUBE, .YELLOW, {0, 1.8, 0}, 0.4)

  app.top_down_camera = render.camera_create(&app.renderer, 512, 512, {0, 8, 0.01}, {0, 0, 0}, math.PI * 0.5, 0.1, 100.0)
  app.screen_material = render.material_create(&app.renderer, render.make_material())
  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XY, app.screen_material, cast_shadow = false), {0, 2.5, -3.5}, scale = 3.0)
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  app.time += dt
  platform.read_input(&app.platform, &app.input)
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  world.rotate(&app.scene, app.spinner, app.time, linalg.VECTOR3F32_Y_AXIS)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  screen := render.material(&app.renderer, app.screen_material)
  screen.albedo_texture = render.camera_image(&app.renderer, app.top_down_camera, .FINAL_IMAGE, previous_frame = true)
  render.update(&app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
