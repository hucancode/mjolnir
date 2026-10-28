// Debug line primitives: segments, boxes, spheres, circles, arrows, axes; timed and depth-bypassing lines.
package main

import "mjolnir"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

TRAIL_PERIOD :: 0.25
TRAIL_LIFE :: 3.0

App :: struct {
  platform:   platform.Platform,
  scene:      world.World,
  renderer:   render.Renderer,
  input:      input.State,
  orbit:      render.Orbit,
  time:       f32,
  next_trail: f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Debug Draw") do return
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

  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false), {0, -1, 0}, scale = 20.0)

  mjolnir.spawn_mesh(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, .BLUE), {-6, 0, 0}, scale = 0.8)

  app.orbit = render.make_orbit({12, 8, 14}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
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
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  app.time += dt
  t := app.time
  white := render.COLOR_RGB[.WHITE]

  render.debug_axes(&app.renderer, {0, 0, 0}, scale = 2)

  render.debug_segment(&app.renderer, {-8, 0, -8}, {8, 0, -8}, white)
  render.debug_segment(&app.renderer, {-8, 0, -8}, {-8, 6, -8}, white)
  render.debug_segment(&app.renderer, {8, 0, -8}, {8, 6, -8}, white)
  render.debug_segment(&app.renderer, {-8, 6, -8}, {8, 6, -8}, white)

  render.debug_aabb(&app.renderer, {-7, -1, -1}, {-5, 1, 1}, render.COLOR_RGB[.GREEN])

  rot := linalg.quaternion_angle_axis_f32(t, {0, 1, 0})
  render.debug_cube(&app.renderer, {-2, 1, 0}, rotation = rot, half_extents = 0.75, color = render.COLOR_RGB[.MAGENTA])

  r := 1.0 + 0.3 * math.sin(t * 2)
  render.debug_sphere(&app.renderer, {2, 1, 0}, radius = r, color = render.COLOR_RGB[.CYAN])

  render.debug_circle(&app.renderer, {6, 0.01, 0}, normal = {0, 1, 0}, radius = 1.5, color = render.COLOR_RGB[.YELLOW])
  render.debug_circle(&app.renderer, {6, 2, 0}, normal = linalg.normalize([3]f32{1, 1, 0}), radius = 1.0, color = render.COLOR_RGB[.ORANGE])

  target := [3]f32{4 * math.cos(t), 3, 4 * math.sin(t)}
  render.debug_arrow(&app.renderer, {0, 3, 0}, target, render.COLOR_RGB[.RED])
  render.debug_point(&app.renderer, target, size = 0.3, color = white)

  if t >= app.next_trail {
    app.next_trail += TRAIL_PERIOD
    angle := t * 1.5
    render.debug_sphere(&app.renderer, {5 * math.cos(angle), 0.5, 5 * math.sin(angle)}, 0.25, render.COLOR_RGB[.GREEN], life = TRAIL_LIFE)
  }

  render.debug_sphere(&app.renderer, {0, 5, 0}, 0.4, render.COLOR_RGB[.CYAN])
  render.debug_sphere(&app.renderer, {0, 6, 0}, 0.4, render.COLOR_RGB[.MAGENTA])
  render.debug_arrow(&app.renderer, {0, 5, 0}, {0, 6, 0}, white)
  render.debug_axes(&app.renderer, {-6, 0, 0}, scale = 1.5, bypass_depth = true)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}
