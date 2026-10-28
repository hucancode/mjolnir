// Vortex force field dragging particles around it.
package main

import "mjolnir"
import "mjolnir/debugui"
import "mjolnir/input"
import "mjolnir/platform"
import "mjolnir/render"
import "mjolnir/world"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

EMITTER_SIZE_START :: 100
EMITTER_SIZE_END :: 30

App :: struct {
  platform: platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  orbit:    render.Orbit,
  time:     f32,
  repel:    Field,
  attract:  Field,
}

Field :: struct {
  pivot:      world.NodeHandle,
  node:       world.NodeHandle,
  handle:     render.ForceFieldHandle,
  color:      [4]f32,
  enabled:    bool,
  area:       f32,
  spin_speed: f32,
  spin_dir:   f32,
}

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  if !platform.init(&app.platform, 1280, 720, "Forcefield") do return
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
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.platform)
  free(app)
}

spawn_field :: proc(
  app: ^App,
  orbit_radius: f32,
  strength, tangent, area: f32,
  color: [4]f32,
  spin_speed, spin_dir: f32,
) -> Field {
  f := Field{color = color, enabled = true, area = area, spin_speed = spin_speed, spin_dir = spin_dir}
  f.pivot = world.spawn(&app.scene, {0, 2, 0})
  f.node = world.spawn(&app.scene, {orbit_radius, 0, 0}, parent = f.pivot)
  f.handle = render.force_field_create(&app.renderer, render.make_force_field(area_of_effect = area, strength = strength, tangent_strength = tangent))
  render.attach(&app.renderer, f.node, f.handle)
  return f
}

setup :: proc(app: ^App) -> mjolnir.Setup {
  if !render.ready(&app.renderer) do return .WAIT
  if !debugui.init(&app.debug, &app.renderer) do return .FAIL
  app.orbit = render.make_orbit({0, 12, 3}, {0, 2, 0})
  render.camera_orbit(render.main_camera(&app.renderer), app.orbit)
  app.renderer.skybox_intensity = 0

  if tex, ok := render.texture_create(&app.renderer, #load("assets/particles/star_09.png")); ok {
    em := render.make_emitter(
      texture           = tex,
      emission_rate     = 100,
      initial_velocity  = {0, 0, 0},
      velocity_spread   = 0.5,
      color_start       = {1, 0.95, 0.4, 1},
      color_end         = {1, 0.2, 0, 0},
      particle_lifetime = 4.0,
      position_spread   = 0.2,
      size_start        = EMITTER_SIZE_START,
      size_end          = EMITTER_SIZE_END,
      weight            = 0.0,
      weight_spread     = 0.0,
    )
    n := world.spawn(&app.scene, {0, 2, 0})
    render.attach(&app.renderer, n, render.emitter_create(&app.renderer, em))
  }

  app.repel = spawn_field(app, 2.5, -15.0, 8.0, 4.0, {0.1, 0.5, 1.0, 1}, 1.2, 1.0)
  app.attract = spawn_field(app, 3.5, 12.0, -5.0, 4.0, {0.2, 1.0, 0.4, 1}, 0.7, -1.0)

  return .READY
}

draw_field_marker :: proc(app: ^App, f: ^Field) {
  position := world.world_matrix(&app.scene, f.node)[3].xyz
  if !f.enabled {
    render.debug_sphere(&app.renderer, position, 0.4, {f.color.r * 0.3, f.color.g * 0.3, f.color.b * 0.3, 1})
    return
  }
  render.debug_sphere(&app.renderer, position, 0.4, f.color)
  render.debug_sphere(&app.renderer, position, f.area, {f.color.r, f.color.g, f.color.b, 0.5})
}

update :: proc(app: ^App, dt: f32) {
  render.lock(&app.renderer)
  defer render.unlock(&app.renderer)
  app.time += dt
  platform.read_input(&app.platform, &app.input)
  debugui.feed(&app.debug, &app.input, &app.renderer)
  debug_ui(app)
  render.stage_overlay(&app.renderer, debugui.end(&app.debug))
  render.orbit_drag(&app.orbit, render.main_camera(&app.renderer), &app.input)
  for f in ([]^Field{&app.repel, &app.attract}) do world.rotate(&app.scene, f.pivot, app.time * f.spin_speed * f.spin_dir, linalg.VECTOR3F32_Y_AXIS)
  world.update(&app.scene)
  for f in ([]^Field{&app.repel, &app.attract}) do draw_field_marker(app, f)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

draw :: proc(app: ^App) -> bool {
  return mjolnir.frame(&app.platform, &app.renderer)
}

field_panel :: proc(app: ^App, ctx: ^mu.Context, name: string, f: ^Field) {
  ff := render.force_field(&app.renderer, f.handle)
  if ff == nil do return
  mu.layout_row(ctx, {-1}, 0)
  mu.checkbox(ctx, name, &f.enabled)
  mu.label(ctx, "Strength")
  mu.slider(ctx, &ff.strength, -30, 30)
  mu.label(ctx, "Tangent")
  mu.slider(ctx, &ff.tangent_strength, -15, 15)
  mu.label(ctx, "Radius")
  mu.slider(ctx, &f.area, 0.5, 10)
  mu.label(ctx, "Spin")
  mu.slider(ctx, &f.spin_speed, 0, 4)
  mu.label(ctx, "")
  ff.area_of_effect = f.area if f.enabled else 0
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if debugui.window(&app.debug, "Forcefields", {20, 20, 300, 550}, {}) {
    field_panel(app, ctx, "Repel (blue)", &app.repel)
    field_panel(app, ctx, "Attract (green)", &app.attract)
  }
}
