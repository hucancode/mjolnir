// Compute-driven particle system.
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

App :: struct {
  platform:      platform.Platform,
  scene:         world.World,
  renderer:      render.Renderer,
  debug:         debugui.Context,
  input:         input.State,
  orbit:         render.Orbit,
  emitter:       render.EmitterHandle,
  textures:      [len(TEXTURE_FILES)]render.TextureHandle,
  emission_rate: f32,
}

TEXTURE_FILES := [?]struct {
  name: string,
  data: []u8,
}{
  {"circle_01", #load("assets/particles/circle_01.png")},
  {"circle_02", #load("assets/particles/circle_02.png")},
  {"circle_03", #load("assets/particles/circle_03.png")},
  {"circle_04", #load("assets/particles/circle_04.png")},
  {"circle_05", #load("assets/particles/circle_05.png")},
  {"light_01",  #load("assets/particles/light_01.png")},
  {"light_02",  #load("assets/particles/light_02.png")},
  {"light_03",  #load("assets/particles/light_03.png")},
  {"symbol_01", #load("assets/particles/symbol_01.png")},
  {"symbol_02", #load("assets/particles/symbol_02.png")},
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  app.emission_rate = 200
  if !platform.init(&app.platform, 1280, 720, "Particles") do return
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
  app.renderer.skybox_intensity = 0
  app.orbit = render.make_orbit({0, 5, 7}, {0, 2, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)

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
  render.attach(&app.renderer, emitter_node, app.emitter)
  return .READY
}

shutdown :: proc(app: ^App) {
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.platform)
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  mjolnir.update(&app.scene, &app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  em := render.emitter(&app.renderer, app.emitter)
  if em == nil do return

  if debugui.window(&app.debug, "Particles", {20, 20, 320, 570}, {}) {
    half := (mu.get_current_container(ctx).body.w - 3 * ctx.style.spacing) / 2
    mu.layout_row(ctx, {half, -1}, 0)
    for file, i in TEXTURE_FILES {
      prefix := "> " if em.texture == app.textures[i] else "  "
      if .SUBMIT in mu.button(ctx, fmt.tprintf("%s%s", prefix, file.name)) do em.texture = app.textures[i]
    }
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Emission rate")
    mu.slider(ctx, &app.emission_rate, 1, 300)
    mu.label(ctx, "Lifetime")
    mu.slider(ctx, &em.particle_lifetime, 0.1, 10)
    mu.label(ctx, "Size start / end")
    mu.layout_row(ctx, {half, -1}, 0)
    mu.slider(ctx, &em.size_start, 1, 1000)
    mu.slider(ctx, &em.size_end, 1, 1000)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Weight")
    mu.slider(ctx, &em.weight, -2, 5)
    mu.label(ctx, "Weight spread")
    mu.slider(ctx, &em.weight_spread, 0, 2)
    mu.label(ctx, "Velocity X / Y / Z")
    third := (mu.get_current_container(ctx).body.w - 4 * ctx.style.spacing) / 3
    mu.layout_row(ctx, {third, third, -1}, 0)
    mu.slider(ctx, &em.initial_velocity.x, -8, 8)
    mu.slider(ctx, &em.initial_velocity.y, -8, 12)
    mu.slider(ctx, &em.initial_velocity.z, -8, 8)
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Velocity spread")
    mu.slider(ctx, &em.velocity_spread, 0, 8)
    mu.label(ctx, "Position spread")
    mu.slider(ctx, &em.position_spread, 0, 4)
  }
  em.emission_rate = app.emission_rate
}
