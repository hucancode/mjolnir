// Compute-driven particle system.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import mu "vendor:microui"

App :: struct {
  window:        platform.Platform,
  scene:         world.World,
  renderer:      render.Renderer,
  debug:         debugui.Context,
  input:         input.State,
  orbit:         render.Orbit,
  emitter:       render.EmitterHandle,
  textures:      [len(TEXTURE_FILES)]render.TextureHandle,
  emission_rate: f32,
  enabled:       bool,
}

TEXTURE_FILES := [?]struct {
  name: string,
  data: []u8,
}{
  {"circle_01", #load("../../assets/particles/circle_01.png")},
  {"circle_02", #load("../../assets/particles/circle_02.png")},
  {"circle_03", #load("../../assets/particles/circle_03.png")},
  {"circle_04", #load("../../assets/particles/circle_04.png")},
  {"circle_05", #load("../../assets/particles/circle_05.png")},
  {"light_01",  #load("../../assets/particles/light_01.png")},
  {"light_02",  #load("../../assets/particles/light_02.png")},
  {"light_03",  #load("../../assets/particles/light_03.png")},
  {"scorch_01", #load("../../assets/particles/scorch_01.png")},
  {"scorch_02", #load("../../assets/particles/scorch_02.png")},
  {"scorch_03", #load("../../assets/particles/scorch_03.png")},
  {"smoke_01",  #load("../../assets/particles/smoke_01.png")},
  {"smoke_02",  #load("../../assets/particles/smoke_02.png")},
  {"smoke_03",  #load("../../assets/particles/smoke_03.png")},
  {"star_01",   #load("../../assets/particles/star_01.png")},
  {"star_02",   #load("../../assets/particles/star_02.png")},
  {"star_03",   #load("../../assets/particles/star_03.png")},
  {"symbol_01", #load("../../assets/particles/symbol_01.png")},
  {"symbol_02", #load("../../assets/particles/symbol_02.png")},
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.emission_rate = 200
  app.enabled = true
  w := &app.window
  if !platform.init(w, 1280, 800, "Particles") do return
  if !render.init(&app.renderer, "Particles", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  app.renderer.skybox_intensity = 0
  render.camera_look_at(render.main_camera(&app.renderer), {0, 5, 10}, {0, 2, 0})
  app.orbit = render.orbit_from_camera(render.main_camera(&app.renderer), {0, 2, 0})

  for file, i in TEXTURE_FILES do app.textures[i] = render.texture_create(&app.renderer, file.data)

  app.emitter = render.emitter_create(&app.renderer, render.make_emitter(
    texture           = app.textures[0],
    emission_rate     = app.emission_rate,
    initial_velocity  = {0, 3, 0},
    velocity_spread   = 1.5,
    color_start       = {1.0, 0.9, 0.4, 1.0},
    color_end         = {1.0, 0.2, 0.0, 0.0},
    particle_lifetime = 2.0,
    position_spread   = 0.3,
    size_start        = 350,
    size_end          = 80,
    weight            = 0.2,
    weight_spread     = 0.1,
  ))
  emitter_node := world.spawn(&app.scene, {0, 2, 0})
  render.attach(&app.renderer, render.SlotHandle(emitter_node.index), app.emitter)
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
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
  debugui.feed(&app.debug, &app.input)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  if !app.input.mouse_captured {
    drag := app.input.mouse_delta if input.mouse_down(&app.input, .LEFT) else 0
    render.orbit_drag(&app.orbit, drag, app.input.scroll.y)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  em := render.emitter(&app.renderer, app.emitter)
  if em == nil do return

  if mu.window(ctx, "Texture", {20, 20, 220, 760}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Enabled", &app.enabled)
    for file, i in TEXTURE_FILES {
      prefix := "> " if em.texture == app.textures[i] else "  "
      if .SUBMIT in mu.button(ctx, fmt.tprintf("%s%s", prefix, file.name)) do em.texture = app.textures[i]
    }
  }

  if mu.window(ctx, "Emission & Lifetime", {900, 20, 320, 600}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Emission rate")
    mu.slider(ctx, &app.emission_rate, 1, 300)
    mu.label(ctx, "Lifetime")
    mu.slider(ctx, &em.particle_lifetime, 0.1, 10)
    mu.label(ctx, "Size start (px at 1 unit)")
    mu.slider(ctx, &em.size_start, 1, 1000)
    mu.label(ctx, "Size end (px at 1 unit)")
    mu.slider(ctx, &em.size_end, 1, 1000)
    mu.label(ctx, "Weight")
    mu.slider(ctx, &em.weight, -2, 5)
    mu.label(ctx, "Weight spread")
    mu.slider(ctx, &em.weight_spread, 0, 2)
    mu.label(ctx, "Velocity X")
    mu.slider(ctx, &em.initial_velocity.x, -8, 8)
    mu.label(ctx, "Velocity Y")
    mu.slider(ctx, &em.initial_velocity.y, -8, 12)
    mu.label(ctx, "Velocity Z")
    mu.slider(ctx, &em.initial_velocity.z, -8, 8)
    mu.label(ctx, "Velocity spread")
    mu.slider(ctx, &em.velocity_spread, 0, 8)
    mu.label(ctx, "Position spread")
    mu.slider(ctx, &em.position_spread, 0, 4)
  }
  em.emission_rate = app.emission_rate if app.enabled else 0
}
