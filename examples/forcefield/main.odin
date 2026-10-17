// Vortex force field dragging particles around it.
package main

import "../../mjolnir"
import "../../mjolnir/debugui"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Renderer,
  debug:    debugui.Context,
  input:    input.State,
  time:     f32,
  // orbit controller state, owned by the app
  yaw, pitch, dist: f32,
}

FFState :: struct {
  parent:           world.NodeHandle,
  ff_node:          world.NodeHandle,
  color:            [4]f32,
  enabled:          bool,
  strength:         mu.Real,
  tangent_strength: mu.Real,
  area_of_effect:   mu.Real,
  spin_speed:       mu.Real,
  spin_dir:         f32,
}

repel:   FFState
attract: FFState

main :: proc() {
  context.logger = log.create_console_logger()
  app := new(App)
  w := &app.window
  if !platform.init(w, 1100, 720, "Forcefield") do return
  if !render.init(&app.renderer, "Forcefield", w.window, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
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
  world.shutdown(&app.scene)
  debugui.shutdown(&app.debug)
  render.shutdown(&app.renderer)
  platform.shutdown(&app.window)
  free(app)
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

spawn_field :: proc(
  app: ^App,
  offset_x: f32,
  strength, tangent, area: f32,
  color: [4]f32,
  spin_speed, spin_dir: f32,
) -> FFState {
  s: FFState
  s.parent = world.spawn(&app.scene, {0, 2, 0})
  s.ff_node = world.spawn(&app.scene, {offset_x, 0, 0}, parent = s.parent)
  render.attach(&app.renderer, render.SlotHandle(s.ff_node.index), render.force_field_create(&app.renderer, render.make_force_field(area_of_effect = area, strength = strength, tangent_strength = tangent)))
  s.color = color
  s.enabled = true
  s.strength = mu.Real(strength)
  s.tangent_strength = mu.Real(tangent)
  s.area_of_effect = mu.Real(area)
  s.spin_speed = mu.Real(spin_speed)
  s.spin_dir = spin_dir
  return s
}

// On the web the renderer's device arrives after main returns: build the scene once it is up.
setup :: proc(app: ^App) -> bool {
  if !render.ready(&app.renderer) do return false
  if !debugui.init(&app.debug, &app.renderer) do return false
  render.environment_map_load(&app.renderer, #load("../../assets/Cannon_Exterior.hdr"))
  render.camera_look_at(render.main_camera(&app.renderer), {0, 12, 3}, {0, 2, 0})
  app.yaw, app.pitch, app.dist = render.camera_orbit_state(render.main_camera(&app.renderer))
  app.renderer.skybox_intensity = 0

  // Particle source at center, large position spread
  if tex, ok := render.texture_create(&app.renderer, #load("../../assets/particles/star_09.png")); ok {
    em := render.make_emitter(
      texture           = tex,
      emission_rate     = 100,
      initial_velocity  = {0, 0, 0},
      velocity_spread   = 0.5,
      color_start       = {1, 0.95, 0.4, 1},
      color_end         = {1, 0.2, 0, 0},
      particle_lifetime = 4.0,
      position_spread   = 0.2,
      size_start        = 100,
      size_end          = 30,
      weight            = 0.0,
      weight_spread     = 0.0,
    )
    n := world.spawn(&app.scene, {0, 2, 0})
    render.attach(&app.renderer, render.SlotHandle(n.index), render.emitter_create(&app.renderer, em))
  }

  // Repulsion field — blue marker
  repel = spawn_field(app, 2.5, -15.0, 8.0, 4.0, {0.1, 0.5, 1.0, 1}, 1.2, 1.0)
  // Attraction field — green marker, opposite spin, slower, larger orbit radius
  attract = spawn_field(app, 3.5, 12.0, -5.0, 4.0, {0.2, 1.0, 0.4, 1}, 0.7, -1.0)

  light := world.spawn(&app.scene, {3, 6, 3})
  render.attach(&app.renderer, render.SlotHandle(light.index), render.light_create(&app.renderer, render.make_directional_light(color = {1, 1, 1, 1}, shadow_radius = 10)))
  return true
}

apply_ff :: proc(app: ^App, s: ^FFState) {
  ff, ok := render.force_field(&app.renderer, render.attachment(&app.renderer, render.SlotHandle(s.ff_node.index), render.ForceFieldHandle))
  if !ok do return
  ff.strength         = f32(s.strength)
  ff.tangent_strength = f32(s.tangent_strength)
  // a zero area pauses the field
  ff.area_of_effect   = f32(s.area_of_effect) if s.enabled else 0
}

draw_ff_marker :: proc(app: ^App, s: ^FFState) {
  if _, ok := world.node(&app.scene, s.ff_node); !ok do return
  pos := world.world_matrix(&app.scene, s.ff_node)[3].xyz
  c := s.color
  if !s.enabled do c = {c.r * 0.3, c.g * 0.3, c.b * 0.3, 1}
  render.debug_sphere(&app.renderer, pos, 0.4, c)
  if s.enabled {
    render.debug_sphere(&app.renderer, pos, f32(s.area_of_effect), {c.r, c.g, c.b, 0.5})
  }
}

update :: proc(app: ^App, dt: f32) {
  app.time += dt
  platform.read_input(&app.window, &app.input)
  debugui.feed(&app.debug, &app.input)
  if !app.input.mouse_captured {
    if input.mouse_down(&app.input, .LEFT) {
      app.yaw += app.input.mouse_delta.x * 0.02
      app.pitch = clamp(app.pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    app.dist = clamp(app.dist - app.input.scroll.y * 2, 1, 200)
  }
  render.camera_orbit(render.main_camera(&app.renderer), app.yaw, app.pitch, app.dist)
  t := app.time
  world.rotate(&app.scene, repel.parent,   t * f32(repel.spin_speed)   * repel.spin_dir,   linalg.VECTOR3F32_Y_AXIS)
  world.rotate(&app.scene, attract.parent, t * f32(attract.spin_speed) * attract.spin_dir, linalg.VECTOR3F32_Y_AXIS)
  apply_ff(app, &repel)
  apply_ff(app, &attract)
  draw_ff_marker(app, &repel)
  draw_ff_marker(app, &attract)
  world.update(&app.scene)
  render.stage_transforms(&app.renderer, world.changes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  render.stage_overlay(&app.renderer, {commands = debugui.end(&app.debug, platform.dpi_scale(&app.window))})
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

ff_panel :: proc(ctx: ^mu.Context, name: string, s: ^FFState) {
  mu.layout_row(ctx, {-1}, 0)
  mu.checkbox(ctx, name, &s.enabled)
  mu.label(ctx, "Strength")
  mu.slider(ctx, &s.strength, -30, 30)
  mu.label(ctx, "Tangent")
  mu.slider(ctx, &s.tangent_strength, -15, 15)
  mu.label(ctx, "Radius")
  mu.slider(ctx, &s.area_of_effect, 0.5, 10)
  mu.label(ctx, "Spin")
  mu.slider(ctx, &s.spin_speed, 0, 4)
  mu.label(ctx, "")
}

debug_ui :: proc(app: ^App) {
  ctx := debugui.begin(&app.debug)
  if mu.window(ctx, "Forcefields", {780, 20, 300, 520}, {.NO_CLOSE}) {
    ff_panel(ctx, "Repel (blue)",   &repel)
    ff_panel(ctx, "Attract (green)", &attract)
  }
}
