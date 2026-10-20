// Trail: a point moving at varying speed, and the path it recorded one point per step of travel.
package main

import "../../mjolnir"
import "../../mjolnir/animation"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

LENGTH :: f32(6)
STEP :: f32(0.5)
SPACING :: f32(0.7)
SAMPLES :: 8
// the sample whose two neighbouring recorded points are highlighted
SHOWN :: 3
LIFT :: [3]f32{0, 0.02, 0}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  orbit:    render.Orbit,
  trail:    animation.Trail([2]f32),
  time:     f32,
  phase:    f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1024, 768, "Trail") do return
  if !render.init(&app.renderer, "Trail", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

course :: proc(phase: f32) -> [2]f32 {
  return {6 * math.sin(phase), 4 * math.sin(2 * phase)}
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT

  ground := world.spawn(&app.scene, {0, -0.01, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY))
  world.scale(&app.scene, ground, 20)

  start := course(0)
  animation.trail_init(&app.trail, start, linalg.normalize(start - course(-0.01)), LENGTH, STEP)

  render.camera_look_at(render.main_camera(&app.renderer), {0, 14, 7}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 0, 0})
  return .READY
}

shutdown :: proc(app: ^App) {
  animation.trail_destroy(&app.trail)
  world.shutdown(&app.scene)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

ground :: proc(p: [2]f32) -> [3]f32 {
  return {p.x, 0, p.y} + LIFT
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

  app.time += dt
  app.phase += dt * (0.5 + 0.3 * math.sin(app.time))
  animation.trail_move(&app.trail, course(app.phase))
  draw(app)

  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

draw :: proc(app: ^App) {
  r := &app.renderer
  trail := app.trail
  for p, i in trail.points {
    render.debug_point(r, ground(p), 0.2, render.DEBUG_YELLOW)
    if i > 0 do render.debug_segment(r, ground(trail.points[i - 1]), ground(p), render.DEBUG_GRAY)
  }
  render.debug_segment(r, ground(trail.head), ground(trail.points[0]), render.DEBUG_ORANGE)
  render.debug_sphere(r, ground(trail.head), 0.25, render.DEBUG_RED)

  previous := trail.head
  for i in 0 ..< SAMPLES {
    back := f32(i + 1) * SPACING
    sample := animation.trail_sample(trail, back)
    render.debug_sphere(r, ground(sample), 0.12, render.DEBUG_CYAN)
    render.debug_segment(r, ground(previous), ground(sample), render.DEBUG_GREEN)
    previous = sample
    if i != SHOWN do continue
    at := (back - trail.lag) / trail.step
    older := min(int(at), len(trail.points) - 2)
    render.debug_segment(r, ground(trail.points[older]), ground(trail.points[older + 1]), render.DEBUG_WHITE)
  }
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
