// Spline evaluation: the curve and its control points, and cubes travelling it at uniform speed.
package main

import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import "core:math"
import "core:math/ease"

CUBE_COUNT :: 16
ANIMATION_DURATION :: 8.0

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  time:     f32,
  cubes:    [CUBE_COUNT]world.NodeHandle,
  spline:   geometry.Spline([3]f32),
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Spline") do return
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
  geometry.destroy(&app.spline)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  app.orbit = render.make_orbit({0, 7, 5.5}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  CONTROL_POINTS :: 10
  points: [CONTROL_POINTS][3]f32
  times: [CONTROL_POINTS]f32
  for i in 0 ..< CONTROL_POINTS {
    t := f32(i) * 2.0 * math.PI / f32(CONTROL_POINTS - 1)
    scale :: 5.0
    points[i] = {scale * math.sin(t), 0, scale * math.sin(2.0 * t) * 0.5}
    times[i] = f32(i) * ANIMATION_DURATION / f32(CONTROL_POINTS - 1)
  }
  if !geometry.spline_init(&app.spline, points[:], times[:]) do log.error("Spline validation failed!")

  colors := [?]render.Color{.RED, .GREEN, .BLUE, .YELLOW, .CYAN, .MAGENTA, .WHITE, .GRAY, .BLACK}
  for &cube, i in app.cubes {
    cube = mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, colors[i % len(colors)]), scale = 0.3)
  }
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false), {0, -2, 0}, scale = 20.0)
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  app.time += dt
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  total_length := geometry.spline_arc_length(app.spline)
  for cube, i in app.cubes {
    offset := f32(i) / f32(CUBE_COUNT) * total_length
    distance := math.mod_f32(app.time * (total_length / ANIMATION_DURATION) + offset, total_length)
    eased := ease.ease(.Quadratic_In_Out, distance / total_length) * total_length
    world.translate(&app.scene, cube, geometry.spline_sample_uniform(app.spline, eased))
  }
  draw_spline(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

draw_spline :: proc(app: ^App) {
  CURVE_SEGMENTS :: 200
  duration := geometry.spline_duration(app.spline)
  prev := geometry.spline_sample(app.spline, 0)
  for i in 1 ..= CURVE_SEGMENTS {
    next := geometry.spline_sample(app.spline, f32(i) / CURVE_SEGMENTS * duration)
    render.debug_segment(&app.renderer, prev, next, render.COLOR_RGB[.WHITE])
    prev = next
  }
  for p in app.spline.points do render.debug_point(&app.renderer, p, size = 0.5, color = render.COLOR_RGB[.YELLOW])
}
