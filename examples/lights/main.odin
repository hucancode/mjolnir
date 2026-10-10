package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

dir_light: world.NodeHandle
point_light: world.NodeHandle
spot_light: world.NodeHandle

dir_enabled: bool = true
point_enabled: bool = true
spot_enabled: bool = true

dir_intensity: mu.Real = 1.0
point_intensity: mu.Real = 1.0
spot_intensity: mu.Real = 1.0

point_radius: mu.Real = 10.0
spot_radius: mu.Real = 20.0
spot_outer_deg: mu.Real = 28.0

dir_color: mu.Real = 0.0
point_color: mu.Real = 0.0
spot_color: mu.Real = 1.0

point_orbit_phase: f32
spot_sweep_phase: f32

main :: proc() {
  mjolnir.run_app({
    title      = "Lights",
    width      = 1000,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

color_preset :: proc(idx: mu.Real, intensity: f32) -> [4]f32 {
  switch int(idx + 0.5) {
  case 0: return {1.0, 0.65, 0.35, intensity}
  case 1: return {1.0, 1.0, 1.0, intensity}
  case 2: return {0.45, 0.7, 1.0, intensity}
  }
  return {1.0, 1.0, 1.0, intensity}
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {7, 6, 7}, {0, 1, 0})

  mjolnir.spawn_ground(engine, 10.0)

  for x in 0 ..< 3 do for z in 0 ..< 3 {
    color: render.Color
    switch (x + z) % 3 {
    case 0: color = .WHITE
    case 1: color = .RED
    case 2: color = .CYAN
    }
    mjolnir.spawn_primitive_mesh(engine, .SPHERE, color, position = {f32(x - 1) * 2.5, 0.7, f32(z - 1) * 2.5}, scale_factor = 0.7)
  }
  mjolnir.spawn_primitive_mesh(engine, .CUBE, .YELLOW, position = {0, 1.5, 0}, scale_factor = 0.6)

  dir_light = mjolnir.spawn(engine, {6, 10, 6}, render.directional_light_attachment(color = color_preset(dir_color, f32(dir_intensity)), radius = 12.0, cast_shadow = true))
  point_light = mjolnir.spawn(engine, {3, 2, 3}, render.point_light_attachment(color = color_preset(point_color, f32(point_intensity)), radius = f32(point_radius)))
  spot_light = mjolnir.spawn(engine, {-4, 5, 0}, render.spot_light_attachment(color = color_preset(spot_color, f32(spot_intensity)), radius = f32(spot_radius), angle = math.PI * f32(spot_outer_deg) / 180.0))

  log.info("Lights — toggle each via UI, live tune color/intensity")
}

apply_light_settings :: proc(engine: ^mjolnir.Engine) {
  if l, ok := render.attachment(&engine.render, dir_light.index, render.DirectionalLightAttachment); ok {
    l.disabled = !dir_enabled
    l.color = color_preset(dir_color, f32(dir_intensity))
    render.mark_slot_dirty(&engine.render, dir_light.index)
  }
  if l, ok := render.attachment(&engine.render, point_light.index, render.PointLightAttachment); ok {
    l.disabled = !point_enabled
    l.color = color_preset(point_color, f32(point_intensity))
    l.radius = f32(point_radius)
    render.mark_slot_dirty(&engine.render, point_light.index)
  }
  if l, ok := render.attachment(&engine.render, spot_light.index, render.SpotLightAttachment); ok {
    l.disabled = !spot_enabled
    l.color = color_preset(spot_color, f32(spot_intensity))
    l.radius = f32(spot_radius)
    l.angle_outer = math.PI * f32(spot_outer_deg) / 180.0
    l.angle_inner = l.angle_outer * render.SPOT_LIGHT_INNER_RATIO
    render.mark_slot_dirty(&engine.render, spot_light.index)
  }
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  point_orbit_phase += dt * 0.7
  world.translate(&engine.world, point_light, math.cos(point_orbit_phase) * 4.0, 2.5 + math.sin(point_orbit_phase * 1.3) * 0.8, math.sin(point_orbit_phase) * 4.0)

  spot_sweep_phase += dt * 0.5
  pos := [3]f32{math.cos(spot_sweep_phase) * 6.0, 5.0 + math.sin(spot_sweep_phase * 0.7) * 1.5, math.sin(spot_sweep_phase) * 6.0}
  world.translate(&engine.world, spot_light, pos)
  dir := linalg.normalize([3]f32{0, 0.5, 0} - pos)
  world.rotate(&engine.world, spot_light, linalg.quaternion_between_two_vector3(linalg.VECTOR3F32_Z_AXIS, dir))
  apply_light_settings(engine)
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Lights", {700, 20, 280, 600}, {.NO_CLOSE}) {
    light_block(ctx, "Directional", &dir_enabled, &dir_intensity, nil, nil, &dir_color)
    light_block(ctx, "Point (orbit)", &point_enabled, &point_intensity, &point_radius, nil, &point_color)
    light_block(ctx, "Spot", &spot_enabled, &spot_intensity, &spot_radius, &spot_outer_deg, &spot_color)
  }
}

light_block :: proc(ctx: ^mu.Context, name: string, enabled: ^bool, intensity: ^mu.Real, radius: ^mu.Real, cone: ^mu.Real, color: ^mu.Real) {
  mu.layout_row(ctx, {-1}, 0)
  mu.checkbox(ctx, fmt.tprintf("%s", name), enabled)
  mu.label(ctx, "Intensity:")
  mu.slider(ctx, intensity, 0.0, 20.0)
  if radius != nil {
    mu.label(ctx, "Range:")
    mu.slider(ctx, radius, 1.0, 30.0)
  }
  if cone != nil {
    mu.label(ctx, "Cone angle (deg):")
    mu.slider(ctx, cone, 5.0, 80.0)
  }
  mu.label(ctx, "Color: 0=warm 1=neutral 2=cool")
  mu.slider(ctx, color, 0.0, 2.0, 1.0)
}
