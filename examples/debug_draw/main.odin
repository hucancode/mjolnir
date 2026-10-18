// Line-strip primitives and debug bone overlay.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

TRAIL_PERIOD :: 0.25
TRAIL_LIFE :: 3.0

App :: struct {
  window:     platform.Platform,
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
  w := &app.window
  if !platform.init(w, 1024, 768, "Debug Draw") do return
  if !render.init(&app.renderer, "Debug Draw", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT

  ground := world.spawn(&app.scene, {0, -1, 0})
  render.attach(&app.renderer, render.SlotHandle(ground.index), render.primitive(&app.renderer, .QUAD_XZ, .GRAY))
  world.scale(&app.scene, ground, 20.0)

  occluder := world.spawn(&app.scene, {-6, 0, 0})
  render.attach(&app.renderer, render.SlotHandle(occluder.index), render.primitive(&app.renderer, .CUBE, .BLUE))
  world.scale(&app.scene, occluder, 0.8)

  render.camera_look_at(render.main_camera(&app.renderer), {12, 8, 14}, {0, 0, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 0, 0})
  return .READY
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
  t := app.time
  white := render.DEBUG_WHITE

  render.debug_axes(&app.renderer, {0, 0, 0}, scale = 2)

  render.debug_segment(&app.renderer, {-8, 0, -8}, {8, 0, -8}, white)
  render.debug_segment(&app.renderer, {-8, 0, -8}, {-8, 6, -8}, white)
  render.debug_segment(&app.renderer, {8, 0, -8}, {8, 6, -8}, white)
  render.debug_segment(&app.renderer, {-8, 6, -8}, {8, 6, -8}, white)

  render.debug_aabb(&app.renderer, {-7, -1, -1}, {-5, 1, 1}, render.DEBUG_GREEN)

  rot := linalg.quaternion_angle_axis_f32(t, {0, 1, 0})
  render.debug_cube(&app.renderer, {-2, 1, 0}, rotation = rot, half_extents = 0.75, color = render.DEBUG_MAGENTA)

  r := 1.0 + 0.3 * math.sin(t * 2)
  render.debug_sphere(&app.renderer, {2, 1, 0}, radius = r, color = render.DEBUG_CYAN)

  render.debug_circle(&app.renderer, {6, 0.01, 0}, normal = {0, 1, 0}, radius = 1.5, color = render.DEBUG_YELLOW)
  render.debug_circle(&app.renderer, {6, 2, 0}, normal = linalg.normalize([3]f32{1, 1, 0}), radius = 1.0, color = render.DEBUG_ORANGE)

  target := [3]f32{4 * math.cos(t), 3, 4 * math.sin(t)}
  render.debug_arrow(&app.renderer, {0, 3, 0}, target, render.DEBUG_RED)
  render.debug_point(&app.renderer, target, size = 0.3, color = white)

  if t >= app.next_trail {
    app.next_trail += TRAIL_PERIOD
    angle := t * 1.5
    render.debug_sphere(&app.renderer, {5 * math.cos(angle), 0.5, 5 * math.sin(angle)}, 0.25, render.DEBUG_GREEN, life = TRAIL_LIFE)
  }

  render.debug_sphere(&app.renderer, {0, 5, 0}, 0.4, render.DEBUG_CYAN)
  render.debug_sphere(&app.renderer, {0, 6, 0}, 0.4, render.DEBUG_MAGENTA)
  render.debug_arrow(&app.renderer, {0, 5, 0}, {0, 6, 0}, white)
  render.debug_axes(&app.renderer, {-6, 0, 0}, scale = 1.5, bypass_depth = true)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
