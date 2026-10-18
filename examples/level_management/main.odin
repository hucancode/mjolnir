// Unloading and reloading levels: Sponza and Amazon Lumberyard Bistro.
// Sponza: Crytek, via Khronos glTF-Sample-Assets (Cryengine Limited License Agreement).
// Bistro: Amazon Lumberyard Bistro v5.2 (CC BY 4.0), glTF conversion by neftaly/bistro-gltf; the
// Exterior scene, textures capped at 512px.
package main

import "core:fmt"
import "core:log"
import mu "vendor:microui"
import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/gltf"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"

AUTOMATED_TEST :: #config(AUTOMATED_TEST, false)

Level :: struct {
  name:     string,
  path:     string,
  target:   [3]f32,
  distance: f32,
  sun:      Maybe([3]f32),
  scale:    f32,
  reach:    f32,
  shadow:   f32,
}

LEVELS :: [?]Level {
  {"Sponza", "assets/Sponza.glb", {0, 3, 0}, 9, [3]f32{-4, 14, 6}, 1, 0, 18},
  {"Bistro", "assets/Bistro.glb", {25, 8, 0}, 60, nil, 1e-5, 15, 120},
}

App :: struct {
  window:          platform.Platform,
  scene:           world.World,
  renderer:        render.Renderer,
  debug:           debugui.Context,
  input:           input.State,
  orbit:           render.Orbit,
  model:           gltf.Model,
  level:           gltf.Instance,
  current:         int,
  requested:       int,
  loads:           int,
  test_frame:      int,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1100, 760, "Level Management") do return
  if !render.init(&app.renderer, "Level Management", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer, {1100, 760}) do return .FAIL
  render.setup(&app.renderer)
  app.current = -1
  app.requested = -1
  if !build_level(app, 0) do return .FAIL
  return .READY
}

build_level :: proc(app: ^App, index: int) -> bool {
  levels := LEVELS
  l := levels[index]
  data := platform.read_file(l.path) or_return
  defer delete(data)
  app.model = gltf.model_create(&app.renderer, data) or_return
  app.level = gltf.instance_create(&app.model, &app.scene, &app.renderer) or_return
  render.camera_look_at(render.main_camera(&app.renderer), l.target + {l.distance, l.distance * 0.1, 0}, l.target)
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), l.target)
  app.renderer.sun = render.DEFAULT_SUN
  app.renderer.sun.enabled = l.sun != nil
  app.renderer.sun.shadow_distance = l.shadow
  for handle in app.model.lights {
    light := render.light(&app.renderer, handle) or_continue
    light.intensity *= l.scale
    light.radius = l.reach
  }
  app.current = index
  app.loads += 1
  log.infof("level %s built: %d nodes, %d meshes, %d materials, %d textures (load #%d)", l.name, len(app.model.nodes), len(app.model.meshes), len(app.model.materials), len(app.model.textures), app.loads)
  return true
}

destroy_level :: proc(app: ^App) {
  gltf.destroy(&app.level, &app.scene)
  gltf.destroy(&app.model, &app.renderer)
  world.teardown(&app.scene)
  render.teardown(&app.renderer)
  app.current = -1
}

shutdown :: proc(app: ^App) {
  destroy_level(app)
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  if app.requested >= 0 {
    index := app.requested
    app.requested = -1
    destroy_level(app)
    if index < len(LEVELS) do build_level(app, index)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  when AUTOMATED_TEST do run_test_step(app)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

run_test_step :: proc(app: ^App) {
  app.test_frame += 1
  switch app.test_frame {
  case 5:
    app.requested = 1
  case 15:
    app.requested = 0
  case 25:
    app.requested = app.current
  case 35:
    app.requested = len(LEVELS)
  case 45:
    log.info("automated test sequence complete")
  }
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Level Management", {20, 20, 320, 340}, {}, {.NO_CLOSE}) {
    levels := LEVELS
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, fmt.tprintf("Level:     %s", levels[app.current].name if app.current >= 0 else "none"))
    mu.label(ctx, fmt.tprintf("Nodes:     %d", len(app.model.nodes)))
    mu.label(ctx, fmt.tprintf("Meshes:    %d", len(app.model.meshes)))
    mu.label(ctx, fmt.tprintf("Materials: %d", len(app.model.materials)))
    mu.label(ctx, fmt.tprintf("Textures:  %d", len(app.model.textures)))
    mu.label(ctx, fmt.tprintf("Loads:     %d", app.loads))
    for l, i in levels do if .SUBMIT in mu.button(ctx, fmt.tprintf("Load %s", l.name)) do app.requested = i
    if .SUBMIT in mu.button(ctx, "Reload Level") do app.requested = app.current
    if .SUBMIT in mu.button(ctx, "Unload Level") do app.requested = len(LEVELS)
  }
}
