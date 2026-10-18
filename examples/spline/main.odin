// Spline evaluation and visualization.
package main

import "../../mjolnir"
import "../../mjolnir/animation"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/ease"

CUBE_COUNT :: 50
ANIMATION_DURATION :: 8.0

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  time:     f32,
  cubes:    [CUBE_COUNT]world.NodeHandle,
  spline:   animation.Spline([3]f32),
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "Spline") do return
  if !render.init(&app.renderer, "Spline", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  animation.destroy(&app.spline)
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
  render.camera_look_at(render.main_camera(&app.renderer), {0, 10, 0}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer))

  CONTROL_POINTS :: 10
  points: [CONTROL_POINTS][3]f32
  times: [CONTROL_POINTS]f32
  for i in 0 ..< CONTROL_POINTS {
    t := f32(i) * 2.0 * math.PI / f32(CONTROL_POINTS - 1)
    scale :: 5.0
    points[i] = {scale * math.sin(t), 0, scale * math.sin(2.0 * t) * 0.5}
    times[i] = f32(i) * ANIMATION_DURATION / f32(CONTROL_POINTS - 1)
  }
  if !animation.spline_init(&app.spline, points[:], times[:]) do log.error("Spline validation failed!")

  colors := [?]render.Color{.RED, .GREEN, .BLUE, .YELLOW, .CYAN, .MAGENTA, .WHITE, .GRAY, .BLACK}
  for &cube, i in app.cubes {
    cube = world.spawn(&app.scene)
    render.attach(&app.renderer, render.SlotHandle(cube.index), render.primitive(&app.renderer, .CUBE, colors[i % len(colors)]))
    world.scale(&app.scene, cube, 0.3)
  }
  ground := world.spawn(&app.scene, {0, -2, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY, cast_shadow = false))
  world.scale(&app.scene, ground, 20.0)
  light := world.spawn(&app.scene, {0, 10, 0})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_point_light({1, 1, 1}, 600, 20.0, true)))
  return .READY
}

update :: proc(app: ^App, dt: f32) {
  app.time += dt
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  total_length := animation.spline_arc_length(app.spline)
  for cube, i in app.cubes {
    offset := f32(i) / f32(CUBE_COUNT) * total_length
    distance := math.mod_f32(app.time * (total_length / ANIMATION_DURATION) + offset, total_length)
    eased := ease.ease(.Quadratic_In_Out, distance / total_length) * total_length
    world.translate(&app.scene, cube, animation.spline_sample_uniform(app.spline, eased))
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
