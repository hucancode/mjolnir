// Arc evaluation: the curve and its control points, and cubes travelling it at uniform speed.
package main

import "core:log"
import "core:math"
import "core:math/ease"
import "core:math/linalg"
import "mjolnir"
import "mjolnir/geometry"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"

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
  arc:      geometry.Arc([3]f32),
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Arc") do return
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
  geometry.destroy(&app.arc)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  sun := render.light_create(&app.renderer, render.make_directional_light())
  mjolnir.spawn(&app.scene, &app.renderer, sun, rotation = linalg.quaternion_from_forward_and_up([3]f32{-0.4, -1, -0.3}, [3]f32{0, 1, 0}))
  app.orbit = render.make_orbit({0, 7, 5.5}, {0, 0, 0})

  // a figure eight, closed: each point written once, the arc running from the last back to the first
  CONTROL_POINTS :: 9
  points: [CONTROL_POINTS][3]f32
  for i in 0 ..< CONTROL_POINTS {
    t := f32(i) * 2.0 * math.PI / f32(CONTROL_POINTS)
    scale :: 5.0
    points[i] = {scale * math.sin(t), 0, scale * math.sin(2.0 * t) * 0.5}
  }
  if !geometry.arc_init(&app.arc, points[:], closed = true) do log.error("Arc validation failed!")

  colors := [?]render.Color{.RED, .GREEN, .BLUE, .YELLOW, .CYAN, .MAGENTA, .WHITE, .GRAY, .BLACK}
  for &cube, i in app.cubes {
    cube = mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .CUBE, colors[i % len(colors)]), scale = 0.3)
  }
  mjolnir.spawn(&app.scene, &app.renderer, render.primitive(&app.renderer, .QUAD_XZ, .GRAY, no_shadow = true), {0, -2, 0}, scale = 20.0)
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  app.time += dt
  platform.read_input(&app.platform, &app.input)
  mjolnir.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  total_length := geometry.arc_length(app.arc)
  for cube, i in app.cubes {
    offset := f32(i) / f32(CUBE_COUNT) * total_length
    distance := math.mod_f32(app.time * (total_length / ANIMATION_DURATION) + offset, total_length)
    eased := ease.ease(.Quadratic_In_Out, distance / total_length) * total_length
    world.transform(&app.scene, cube).position = geometry.arc_sample_uniform(app.arc, eased)
  }
  draw_arc(app)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

draw_arc :: proc(app: ^App) {
  CURVE_SEGMENTS :: 200
  prev := geometry.arc_sample(app.arc, 0)
  for i in 1 ..= CURVE_SEGMENTS {
    next := geometry.arc_sample(app.arc, f32(i) / CURVE_SEGMENTS)
    render.debug_segment(&app.renderer, prev, next, render.COLOR_RGB[.WHITE])
    prev = next
  }
  for p in app.arc.points do render.debug_point(&app.renderer, p, size = 0.5, color = render.COLOR_RGB[.YELLOW])
}
