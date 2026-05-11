package main

import "../../mjolnir"
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

dir_intensity: mu.Real = 4.0
point_intensity: mu.Real = 12.0
spot_intensity: mu.Real = 18.0

point_radius: mu.Real = 10.0
spot_radius: mu.Real = 20.0
spot_outer_deg: mu.Real = 28.0

dir_color: mu.Real = 0.0 // 0=warm 1=neutral 2=cool
point_color: mu.Real = 0.0
spot_color: mu.Real = 1.0

point_orbit_phase: f32
spot_sweep_phase: f32

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 1000, 700, "Lights")
}

color_preset :: proc(idx: mu.Real, intensity: f32) -> [4]f32 {
  switch int(idx + 0.5) {
  case 0:
    return {1.0, 0.65, 0.35, intensity} // warm
  case 1:
    return {1.0, 1.0, 1.0, intensity} // neutral
  case 2:
    return {0.45, 0.7, 1.0, intensity} // cool
  }
  return {1.0, 1.0, 1.0, intensity}
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(&engine.world, {7, 6, 7}, {0, 1, 0})

  // Ground
  ground_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.MeshAttachment{handle = ground_mesh, material = ground_mat, cast_shadow = false},
    ) or_else {}
  world.scale(&engine.world, ground, 10.0)

  // Lit subjects — sphere grid
  for x in 0 ..< 3 {
    for z in 0 ..< 3 {
      color: world.Color
      switch (x + z) % 3 {
      case 0:
        color = .WHITE
      case 1:
        color = .RED
      case 2:
        color = .CYAN
      }
      world.spawn_primitive_mesh(
        &engine.world,
        .SPHERE,
        color,
        position = {f32(x - 1) * 2.5, 0.7, f32(z - 1) * 2.5},
        scale_factor = 0.7,
      )
    }
  }
  // Vertical cube — catches side light, casts shadow
  world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .YELLOW,
    position = {0, 1.5, 0},
    scale_factor = 0.6,
  )

  dir_light =
    world.spawn(
      &engine.world,
      {6, 10, 6},
      world.create_directional_light_attachment(
        color_preset(dir_color, f32(dir_intensity)),
        12.0,
        true,
      ),
    ) or_else {}

  point_light =
    world.spawn(
      &engine.world,
      {3, 2, 3},
      world.create_point_light_attachment(
        color_preset(point_color, f32(point_intensity)),
        f32(point_radius),
        true,
      ),
    ) or_else {}

  spot_light_pos := [3]f32{-4, 5, 0}
  spot_light =
    world.spawn(
      &engine.world,
      spot_light_pos,
      world.create_spot_light_attachment(
        color_preset(spot_color, f32(spot_intensity)),
        f32(spot_radius),
        math.PI * f32(spot_outer_deg) / 180.0,
        true,
      ),
    ) or_else {}
  log.info("=========================================")
  log.info("Lights — toggle each via UI, live tune color/intensity")
  log.info("=========================================")
}

apply_light_settings :: proc(engine: ^mjolnir.Engine) {
  if dn, ok := world.node(&engine.world, dir_light); ok {
    if att, ok := &dn.attachment.(world.DirectionalLightAttachment); ok {
      eff := f32(dir_intensity) if dir_enabled else 0.0
      att.color = color_preset(dir_color, eff)
      world.stage_light_data(&engine.world.staging, dir_light)
    }
  }
  if pn, ok := world.node(&engine.world, point_light); ok {
    if att, ok := &pn.attachment.(world.PointLightAttachment); ok {
      eff := f32(point_intensity) if point_enabled else 0.0
      att.color = color_preset(point_color, eff)
      att.radius = f32(point_radius) if point_enabled else 0.0
      world.stage_light_data(&engine.world.staging, point_light)
    }
  }
  if sn, ok := world.node(&engine.world, spot_light); ok {
    if att, ok := &sn.attachment.(world.SpotLightAttachment); ok {
      eff := f32(spot_intensity) if spot_enabled else 0.0
      att.color = color_preset(spot_color, eff)
      att.radius = f32(spot_radius) if spot_enabled else 0.0
      outer := math.PI * f32(spot_outer_deg) / 180.0
      att.angle_outer = outer
      att.angle_inner = outer * 0.75
      world.stage_light_data(&engine.world.staging, spot_light)
    }
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  // Orbit the point light so user sees range/falloff move
  point_orbit_phase += delta_time * 0.7
  if pn, ok := world.node(&engine.world, point_light); ok {
    pn.transform.position = {
      math.cos(point_orbit_phase) * 4.0,
      2.5 + math.sin(point_orbit_phase * 1.3) * 0.8,
      math.sin(point_orbit_phase) * 4.0,
    }
    pn.transform.is_dirty = true
  }
  // Sweep spot light around scene, always aim at center
  spot_sweep_phase += delta_time * 0.5
  if sn, ok := world.node(&engine.world, spot_light); ok {
    pos := [3]f32 {
      math.cos(spot_sweep_phase) * 6.0,
      5.0 + math.sin(spot_sweep_phase * 0.7) * 1.5,
      math.sin(spot_sweep_phase) * 6.0,
    }
    sn.transform.position = pos
    target := [3]f32{0, 0.5, 0}
    dir := linalg.normalize(target - pos)
    sn.transform.rotation = linalg.quaternion_between_two_vector3(
      linalg.VECTOR3F32_Z_AXIS,
      dir,
    )
    sn.transform.is_dirty = true
  }
  apply_light_settings(engine)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "Lights", {700, 20, 280, 540}, {.NO_CLOSE}) {
    light_block(ctx, "Directional", &dir_enabled, &dir_intensity, nil, nil, &dir_color)
    light_block(ctx, "Point (orbit)", &point_enabled, &point_intensity, &point_radius, nil, &point_color)
    light_block(ctx, "Spot", &spot_enabled, &spot_intensity, &spot_radius, &spot_outer_deg, &spot_color)
  }
}

light_block :: proc(
  ctx: ^mu.Context,
  name: string,
  enabled: ^bool,
  intensity: ^mu.Real,
  radius: ^mu.Real,
  cone: ^mu.Real,
  color: ^mu.Real,
) {
  mu.layout_row(ctx, {-1}, 0)
  mu.label(ctx, fmt.tprintf("--- %s ---", name))
  mu.checkbox(ctx, "Enabled", enabled)
  mu.label(ctx, "Intensity:")
  mu.slider(ctx, intensity, 0.0, 40.0)
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
