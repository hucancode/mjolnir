// Spawning + despawning at scale, with the GPU time of each render pass.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

GRID_SIZES :: [3]int{5, 256, 300}

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  size:     int,
  cubes:    [dynamic]world.NodeHandle,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 800, 600, "Grid") do return
  if !render.init(&app.renderer, app.platform.window) do return
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
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL

  app.orbit = render.make_orbit({14, 14, 14}, {0, 0, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.size = GRID_SIZES[0]
  return .READY
}

shutdown :: proc(app: ^App) {
  delete(app.cubes)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

select_size :: proc(app: ^App, size: int) {
  for cube in app.cubes do world.destroy(&app.scene, cube)
  clear(&app.cubes)
  app.size = size
}

fill_grid :: proc(app: ^App) {
  n := app.size
  half := f32(n) * 0.5
  color := render.Color.GREEN if n > 5 else render.Color.YELLOW
  for len(app.cubes) < n * n {
    x, z := len(app.cubes) % n, len(app.cubes) / n
    cube := world.spawn(&app.scene, {(f32(x) - half) * 4, 0, (f32(z) - half) * 4}) or_break
    render.attach(&app.renderer, render.SlotHandle(cube.index), render.primitive(&app.renderer, .CUBE, color))
    append(&app.cubes, cube)
  }
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, &app.input)
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  fill_grid(app)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.platform)
  return render.frame(&app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Grid", {540, 20, 240, 200}, {.RIGHT, .TOP}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Cubes: %d / %d", len(app.cubes), app.size * app.size))
    for n in GRID_SIZES {
      if .SUBMIT in mu.button(ctx, fmt.tprintf("%dx%d", n, n)) && n != app.size do select_size(app, n)
    }
  }
  if debugui.window(&app.debug, "GPU", {20, 20, 240, 250}, {}, {.NO_CLOSE}) {
    timings := render.gpu_timings(&app.renderer)
    if len(timings) == 0 do mu.label(ctx, "No GPU timers on this device")
    mu.layout_row(ctx, {150, -1}, 0)
    for t in timings {
      mu.label(ctx, fmt.tprintf("%*s%s", int(t.depth) * 2, "", t.name))
      mu.label(ctx, fmt.tprintf("%.3f ms", t.ms))
    }
  }
}
