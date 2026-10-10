package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/render/ambient"
import "../../mjolnir/world"
import "core:fmt"
import "core:math/linalg"
import mu "vendor:microui"

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
  mjolnir.run_app({
    title      = "Forcefield",
    width      = 1100,
    height     = 720,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

spawn_field :: proc(
  engine: ^mjolnir.Engine,
  offset_x: f32,
  strength, tangent, area: f32,
  color: [4]f32,
  spin_speed, spin_dir: f32,
) -> FFState {
  s: FFState
  s.parent = world.spawn(&engine.world, {0, 2, 0})
  s.ff_handle = render.create_forcefield(&engine.render, area_of_effect = area, strength = strength, tangent_strength = tangent)
  s.ff_node = mjolnir.spawn(engine, {offset_x, 0, 0}, render.ForceFieldAttachment{s.ff_handle}, s.parent)
  s.color = color
  s.enabled = true
  s.strength = mu.Real(strength)
  s.tangent_strength = mu.Real(tangent)
  s.area_of_effect = mu.Real(area)
  s.spin_speed = mu.Real(spin_speed)
  s.spin_dir = spin_dir
  return s
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {0, 12, 3}, {0, 2, 0})
  ambient.set_skybox_enabled(&engine.render.ambient, false)

  // Particle source at center, large position spread
  if tex, ret := render.create_texture_from_path(&engine.render, "assets/particles/star_09.png"); ret == .SUCCESS {
    em := render.create_emitter(&engine.render,
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
    mjolnir.spawn(engine, {0, 2, 0}, render.EmitterAttachment{em})
  }

  // Repulsion field — blue marker
  repel = spawn_field(engine, 2.5, -15.0, 8.0, 4.0, {0.1, 0.5, 1.0, 1}, 1.2, 1.0)
  // Attraction field — green marker, opposite spin, slower, larger orbit radius
  attract = spawn_field(engine, 3.5, 12.0, -5.0, 4.0, {0.2, 1.0, 0.4, 1}, 0.7, -1.0)

  mjolnir.spawn(engine, {3, 6, 3}, render.directional_light_attachment(color = {1, 1, 1, 1}, radius = 10))
}

apply_ff :: proc(engine: ^mjolnir.Engine, s: ^FFState) {
  ff, ok := render.forcefield(&engine.render, s.ff_handle)
  if !ok do return
  ff.strength         = f32(s.strength)
  ff.tangent_strength = f32(s.tangent_strength)
  ff.area_of_effect   = f32(s.area_of_effect)
  ff.enabled          = b32(s.enabled)
}

draw_ff_marker :: proc(engine: ^mjolnir.Engine, s: ^FFState) {
  if !world.valid(&engine.world, s.ff_node) do return
  pos := world.world_matrix(&engine.world, s.ff_node)[3].xyz
  c := s.color
  if !s.enabled do c = {c.r * 0.3, c.g * 0.3, c.b * 0.3, 1}
  render.debug_sphere(&engine.render, pos, 0.4, c)
  if s.enabled {
    render.debug_sphere(&engine.render, pos, f32(s.area_of_effect), {c.r, c.g, c.b, 0.5})
  }
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  t := mjolnir.time_since_start(engine)
  world.rotate(&engine.world, repel.parent,   t * f32(repel.spin_speed)   * repel.spin_dir,   linalg.VECTOR3F32_Y_AXIS)
  world.rotate(&engine.world, attract.parent, t * f32(attract.spin_speed) * attract.spin_dir, linalg.VECTOR3F32_Y_AXIS)
  apply_ff(engine, &repel)
  apply_ff(engine, &attract)
  draw_ff_marker(engine, &repel)
  draw_ff_marker(engine, &attract)
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
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

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Forcefields", {780, 20, 300, 520}, {.NO_CLOSE}) {
    ff_panel(ctx, "Repel (blue)",   &repel)
    ff_panel(ctx, "Attract (green)", &attract)
  }
}
