// Wireframe rendering pipeline.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import "core:math/linalg"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  time:     f32,
  cubes:    [9]world.NodeHandle,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "Wireframe") do return
  if !render.init(&app.renderer, "Wireframe", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  render.camera_look_at(render.main_camera(&app.renderer), {0, 4, 9}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 0, 0})
  app.renderer.skybox_intensity = 0

  wireframe := render.material_create(&app.renderer, render.make_material(.WIREFRAME))
  for &cube, i in app.cubes {
    row, col := i / 3, i % 3
    cube = world.spawn(&app.scene, {f32(col - 1) * 2.5, 0, f32(row - 1) * 2.5})
    render.attach(&app.renderer, render.SlotHandle(cube.index), render.primitive(&app.renderer, .CUBE, wireframe, cast_shadow = false))
    world.scale(&app.scene, cube, 0.7)
  }
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  app.time += dt
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  axis := linalg.normalize([3]f32{1, 1, 0.4})
  for cube, i in app.cubes {
    world.rotate(&app.scene, cube, linalg.quaternion_angle_axis(app.time * (0.4 + f32(i) * 0.15), axis))
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
