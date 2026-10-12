package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math/linalg"
import mu "vendor:microui"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  input:    input.State,
  time:     f32,
}

FFState :: struct {
  parent:           world.NodeHandle,
  ff_node:          world.NodeHandle,
  ff_handle:        render.ForceFieldHandle,
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
  defer free(app)
  w := &app.window
  if !platform.init(w, 1100, 720, "Forcefield") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "Forcefield", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  setup(app)
  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
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
  s.ff_handle = render.create_forcefield(&app.renderer, area_of_effect = area, strength = strength, tangent_strength = tangent)
  s.ff_node = world.spawn_child(&app.scene, s.parent, {offset_x, 0, 0})
  render.attach(&app.renderer, s.ff_node.index, render.ForceFieldAttachment{s.ff_handle})
  s.color = color
  s.enabled = true
  s.strength = mu.Real(strength)
  s.tangent_strength = mu.Real(tangent)
  s.area_of_effect = mu.Real(area)
  s.spin_speed = mu.Real(spin_speed)
  s.spin_dir = spin_dir
  return s
}

setup :: proc(app: ^App) {
  render.main_camera_look_at(&app.renderer, {0, 12, 3}, {0, 2, 0})
  app.renderer.ambient.skybox_intensity = 0

  // Particle source at center, large position spread
  if tex, ret := render.create_texture_from_path(&app.renderer, "assets/particles/star_09.png"); ret == .SUCCESS {
    em := render.create_emitter(&app.renderer,
      texture_handle    = tex,
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
    render.attach(&app.renderer, n.index, render.EmitterAttachment{em})
  }

  // Repulsion field — blue marker
  repel = spawn_field(app, 2.5, -15.0, 8.0, 4.0, {0.1, 0.5, 1.0, 1}, 1.2, 1.0)
  // Attraction field — green marker, opposite spin, slower, larger orbit radius
  attract = spawn_field(app, 3.5, 12.0, -5.0, 4.0, {0.2, 1.0, 0.4, 1}, 0.7, -1.0)

  light := world.spawn(&app.scene, {3, 6, 3})
  render.attach(&app.renderer, light.index, render.directional_light_attachment(color = {1, 1, 1, 1}, shadow_radius = 10))
}

apply_ff :: proc(app: ^App, s: ^FFState) {
  ff, ok := render.forcefield(&app.renderer, s.ff_handle)
  if !ok do return
  ff.strength         = f32(s.strength)
  ff.tangent_strength = f32(s.tangent_strength)
  ff.area_of_effect   = f32(s.area_of_effect)
  ff.enabled          = b32(s.enabled)
  render.set_forcefield(&app.renderer, s.ff_handle, ff^)
}

draw_ff_marker :: proc(app: ^App, s: ^FFState) {
  if !world.valid(&app.scene, s.ff_node) do return
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
  render.debug_ui_input(&app.renderer, &app.input)
  if cam, ok := render.main_camera(&app.renderer); ok && !app.input.mouse_captured {
    yaw, pitch, dist := render.camera_orbit_state(cam)
    if input.mouse_down(&app.input, .LEFT) {
      yaw += app.input.mouse_delta.x * 0.02
      pitch = clamp(pitch + app.input.mouse_delta.y * 0.02, -1.5, 1.5)
    }
    render.camera_orbit(cam, yaw, pitch, clamp(dist - app.input.scroll.y * 2, 1, 200))
  }
  t := app.time
  world.rotate(&app.scene, repel.parent,   t * f32(repel.spin_speed)   * repel.spin_dir,   linalg.VECTOR3F32_Y_AXIS)
  world.rotate(&app.scene, attract.parent, t * f32(attract.spin_speed) * attract.spin_dir, linalg.VECTOR3F32_Y_AXIS)
  apply_ff(app, &repel)
  apply_ff(app, &attract)
  draw_ff_marker(app, &repel)
  draw_ff_marker(app, &attract)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  render.stage_transforms(&app.renderer, world.changed_nodes(&app.scene))
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  debug_ui(app)
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}

ff_panel :: proc(ctx: ^mu.Context, name: string, s: ^FFState) {
  mu.layout_row(ctx, {-1}, 0)
  mu.checkbox(ctx, name, &s.enabled)
  mu.label(ctx, fmt.tprintf("Strength: %.2f", f32(s.strength)))
  mu.slider(ctx, &s.strength, -30, 30)
  mu.label(ctx, fmt.tprintf("Tangent: %.2f", f32(s.tangent_strength)))
  mu.slider(ctx, &s.tangent_strength, -15, 15)
  mu.label(ctx, fmt.tprintf("Radius: %.2f", f32(s.area_of_effect)))
  mu.slider(ctx, &s.area_of_effect, 0.5, 10)
  mu.label(ctx, fmt.tprintf("Spin: %.2f", f32(s.spin_speed)))
  mu.slider(ctx, &s.spin_speed, 0, 4)
  mu.label(ctx, "")
}

debug_ui :: proc(app: ^App) {
  ctx := render.debug_ui(&app.renderer)
  if mu.window(ctx, "Forcefields", {780, 20, 300, 520}, {.NO_CLOSE}) {
    ff_panel(ctx, "Repel (blue)",   &repel)
    ff_panel(ctx, "Attract (green)", &attract)
  }
}
