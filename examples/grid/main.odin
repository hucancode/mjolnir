// Spawning + despawning at scale.
package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

GRID_SIZES :: [3]int{5, 256, 300}

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  input:    input.State,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

current_size_index: int = -1
pending_index: int = -1
despawn_cooldown: int
grid_root: world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 800, 600, "Grid") do return
  if !render.init(&app.renderer, "Grid", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  render.load_environment_map(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))

  light := world.spawn(&app.scene, {10, 18, 10})
  render.attach(&app.renderer, light.index, render.directional_light_attachment({1, 0.97, 0.92, 3.0}, 60.0, false))
  world.rotate(&app.scene, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  render.main_camera_look_at(&app.renderer, {14, 14, 14}, {0, 0, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  pending_index = 0
  return true
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

// Split despawn/respawn across FRAMES_IN_FLIGHT frames to let Remove ops drain.
request_rebuild :: proc(idx: int) {
  if idx == current_size_index do return
  pending_index = idx
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  input.feed_microui(&app.input, render.debug_ctx(&app.renderer))
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.main_camera_orbit(&app.renderer, app.yaw, app.pitch, app.dist)
  if despawn_cooldown > 0 {
    despawn_cooldown -= 1
    if despawn_cooldown == 0 do spawn_grid(app, pending_index)
  } else if pending_index >= 0 && pending_index != current_size_index {
    if grid_root.index != 0 do world.despawn(&app.scene, grid_root)
    grid_root = {}
    despawn_cooldown = 2
  }
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

spawn_grid :: proc(app: ^App, idx: int) {
  current_size_index = idx
  pending_index = -1
  sizes := GRID_SIZES
  n := sizes[idx]
  color := render.Color.GREEN if n > 5 else render.Color.YELLOW
  half := f32(n) * 0.5
  log.infof("spawning %dx%d cubes", n, n)
  grid_root = world.spawn(&app.scene, {0, 0, 0})
  for z in 0 ..< n do for x in 0 ..< n {
    cube := world.spawn_child(&app.scene, grid_root, {(f32(x) - half) * 4, 0, (f32(z) - half) * 4})
    render.attach(&app.renderer, cube.index, render.primitive(&app.renderer, .CUBE, color))
  }
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Grid", {540, 20, 240, 200}, {.NO_CLOSE}) {
    sizes := GRID_SIZES
    label_text: string = "<loading>"
    if current_size_index >= 0 do label_text = fmt.tprintf("%dx%d", sizes[current_size_index], sizes[current_size_index])
    mu.label(ctx, fmt.tprintf("Size: %s", label_text))
    mu.label(ctx, "")
    mu.layout_row(ctx, {-1}, 0)
    for n, i in sizes {
      if .SUBMIT in mu.button(ctx, fmt.tprintf("%dx%d", n, n)) do request_rebuild(i)
    }
  }
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
