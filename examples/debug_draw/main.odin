package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

elapsed: f32 = 0

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = pre_render
  engine.post_render_proc = post_render
  mjolnir.run(engine, 1024, 768, "Debug Draw")
}

setup :: proc(engine: ^mjolnir.Engine) {
  light := world.spawn(
    &engine.world,
    {10, 18, 10},
    world.create_directional_light_attachment({1, 0.97, 0.92, 2.0}, 60.0, false),
  ) or_else {}
  world.rotate(&engine.world, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)

  world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .GRAY,
    position = {0, -0.5, 0},
    scale_factor = 0.01,
  )
  ground := world.spawn_primitive_mesh(
    &engine.world,
    .QUAD_XZ,
    .GRAY,
    position = {0, -1, 0},
  ) or_else {}
  world.scale(&engine.world, ground, 20.0)

  // Real cube provides depth-occlusion contrast for the adjacent debug cube.
  world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .BLUE,
    position = {-6, 0, 0},
    scale_factor = 0.8,
  )

  world.main_camera_look_at(&engine.world, {12, 8, 14}, {0, 0, 0})
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  elapsed += dt
  t := elapsed
  white := mjolnir.debug_color(.WHITE)

  mjolnir.debug_axes(engine, {0, 0, 0}, scale = 2)

  mjolnir.debug_segment(engine, {-8, 0, -8}, {8, 0, -8}, white)
  mjolnir.debug_segment(engine, {-8, 0, -8}, {-8, 6, -8}, white)
  mjolnir.debug_segment(engine, { 8, 0, -8}, { 8, 6, -8}, white)
  mjolnir.debug_segment(engine, {-8, 6, -8}, { 8, 6, -8}, white)

  mjolnir.debug_aabb(
    engine,
    {-7, -1, -1},
    {-5, 1, 1},
    mjolnir.debug_color(.GREEN),
  )

  rot := linalg.quaternion_angle_axis_f32(t, {0, 1, 0})
  mjolnir.debug_cube(
    engine,
    {-2, 1, 0},
    rotation = rot,
    size = {1.5, 1.5, 1.5},
    color = mjolnir.debug_color(.MAGENTA),
  )

  r := 1.0 + 0.3 * math.sin(t * 2)
  mjolnir.debug_sphere(
    engine,
    {2, 1, 0},
    radius = r,
    color = mjolnir.debug_color(.CYAN),
  )

  mjolnir.debug_circle(
    engine,
    {6, 0.01, 0},
    normal = {0, 1, 0},
    radius = 1.5,
    color = mjolnir.debug_color(.YELLOW),
  )

  mjolnir.debug_circle(
    engine,
    {6, 2, 0},
    normal = linalg.normalize([3]f32{1, 1, 0}),
    radius = 1.0,
    color = mjolnir.debug_color(.ORANGE),
  )

  target := [3]f32{4 * math.cos(t), 3, 4 * math.sin(t)}
  mjolnir.debug_arrow(engine, {0, 3, 0}, target, mjolnir.debug_color(.RED))

  mjolnir.debug_point(engine, target, size = 0.3, color = white)

  trail_period :: 0.25
  trail_count_total := int(t / trail_period)
  if trail_count_total > 0 {
    last := f32(trail_count_total) * trail_period
    if last > elapsed - dt && last <= elapsed {
      angle := last * 1.5
      pos := [3]f32{5 * math.cos(angle), 0.5, 5 * math.sin(angle)}
      mjolnir.debug_sphere(engine, pos, 0.25, mjolnir.debug_color(.GREEN), life = 3.0)
    }
  }

  // bypass_depth = renders over the real cube.
  mjolnir.debug_axes(
    engine,
    {-6, 0, 0},
    scale = 1.5,
    bypass_depth = true,
  )
}

pre_render :: proc(engine: ^mjolnir.Engine) {
  mjolnir.debug_sphere(engine, {0, 5, 0}, 0.4, mjolnir.debug_color(.CYAN))
}

// post_render_proc fires after record(); these segments appear next frame.
post_render :: proc(engine: ^mjolnir.Engine) {
  mjolnir.debug_sphere(engine, {0, 6, 0}, 0.4, mjolnir.debug_color(.MAGENTA))
  mjolnir.debug_arrow(
    engine,
    {0, 5, 0},
    {0, 6, 0},
    mjolnir.debug_color(.WHITE),
  )
}
