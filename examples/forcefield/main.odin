package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:fmt"
import "core:math/linalg"
import mu "vendor:microui"

FFState :: struct {
  parent:           mjolnir.NodeHandle,
  ff_node:          mjolnir.NodeHandle,
  ff_handle:        mjolnir.ForceFieldHandle,
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
  s.parent = mjolnir.spawn(engine, {0, 2, 0})
  child, ff, _ := mjolnir.spawn_forcefield(
    engine,
    position         = {offset_x, 0, 0},
    area_of_effect   = area,
    strength         = strength,
    tangent_strength = tangent,
  )
  mjolnir.attach(engine, s.parent, child)

  s.ff_node = child
  s.ff_handle = ff
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
  mjolnir.main_camera_look_at(engine, {0, 12, 3}, {0, 2, 0})
  mjolnir.set_skybox_enabled(engine, false)

  // Particle source at center, large position spread
  if tex, ok := mjolnir.create_texture(engine, "assets/particles/star_09.png"); ok {
    mjolnir.spawn_emitter(
      engine,
      position          = {0, 2, 0},
      texture           = tex,
      emission_rate     = 100,
      initial_velocity  = {0, 0, 0},
      velocity_spread   = 0.5,
      color_start       = {1, 0.95, 0.4, 1},
      color_end         = {1, 0.2, 0, 0},
      aabb_min          = {-6, -6, -6},
      aabb_max          = {6, 6, 6},
      particle_lifetime = 4.0,
      position_spread   = 0.2,
      size_start        = 100,
      size_end          = 30,
      weight            = 0.0,
      weight_spread     = 0.0,
    )
  }

  // Repulsion field — blue marker
  repel = spawn_field(engine, 2.5, -15.0, 8.0, 4.0, {0.1, 0.5, 1.0, 1}, 1.2, 1.0)
  // Attraction field — green marker, opposite spin, slower, larger orbit radius
  attract = spawn_field(engine, 3.5, 12.0, -5.0, 4.0, {0.2, 1.0, 0.4, 1}, 0.7, -1.0)

  mjolnir.spawn_light_directional(engine, position = {3, 6, 3}, color = {1, 1, 1, 1}, radius = 10)
}

apply_ff :: proc(engine: ^mjolnir.Engine, s: ^FFState) {
  if s.enabled {
    mjolnir.set_forcefield(engine, s.ff_handle, f32(s.strength), f32(s.tangent_strength), f32(s.area_of_effect))
  } else {
    mjolnir.set_forcefield(engine, s.ff_handle, 0, 0, 0)
  }
}

draw_ff_marker :: proc(engine: ^mjolnir.Engine, s: ^FFState) {
  n, ok := world.node(&engine.world, s.ff_node)
  if !ok do return
  pos := n.transform.world_matrix[3].xyz
  c := s.color
  if !s.enabled do c = {c.r * 0.3, c.g * 0.3, c.b * 0.3, 1}
  mjolnir.debug_sphere(engine, pos, 0.4, c)
  if s.enabled {
    mjolnir.debug_sphere(engine, pos, f32(s.area_of_effect), {c.r, c.g, c.b, 0.5})
  }
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  t := mjolnir.time_since_start(engine)
  mjolnir.rotate(engine, repel.parent,   t * f32(repel.spin_speed)   * repel.spin_dir,   linalg.VECTOR3F32_Y_AXIS)
  mjolnir.rotate(engine, attract.parent, t * f32(attract.spin_speed) * attract.spin_dir, linalg.VECTOR3F32_Y_AXIS)
  apply_ff(engine, &repel)
  apply_ff(engine, &attract)
  draw_ff_marker(engine, &repel)
  draw_ff_marker(engine, &attract)
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
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Forcefields", {780, 20, 300, 520}, {.NO_CLOSE}) {
    ff_panel(ctx, "Repel (blue)",   &repel)
    ff_panel(ctx, "Attract (green)", &attract)
  }
}
