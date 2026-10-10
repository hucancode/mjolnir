package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:math"
import "core:math/linalg"

elapsed: f32 = 0

main :: proc() {
  mjolnir.run_app({
    title       = "Debug Draw",
    width       = 1024,
    height      = 768,
    setup       = setup,
    update      = update,
    pre_render  = pre_render,
    post_render = post_render,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  light := mjolnir.spawn(engine, {10, 18, 10}, render.directional_light_attachment({1, 0.97, 0.92, 2.0}, 60.0, false))
  world.rotate(&engine.world, light, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)

  mjolnir.spawn_primitive_mesh(engine, .CUBE, .GRAY, position = {0, -0.5, 0}, scale_factor = 0.01)
  ground := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY, position = {0, -1, 0})
  world.scale(&engine.world, ground, 20.0)

  // Real cube provides depth-occlusion contrast for the adjacent debug cube.
  mjolnir.spawn_primitive_mesh(engine, .CUBE, .BLUE, position = {-6, 0, 0}, scale_factor = 0.8)

  render.main_camera_look_at(&engine.render, {12, 8, 14}, {0, 0, 0})
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  elapsed += dt
  t := elapsed
  white := render.debug_color(.WHITE)

  render.debug_axes(&engine.render, {0, 0, 0}, scale = 2)

  render.debug_segment(&engine.render, {-8, 0, -8}, {8, 0, -8}, white)
  render.debug_segment(&engine.render, {-8, 0, -8}, {-8, 6, -8}, white)
  render.debug_segment(&engine.render, {8, 0, -8}, {8, 6, -8}, white)
  render.debug_segment(&engine.render, {-8, 6, -8}, {8, 6, -8}, white)

  render.debug_aabb(&engine.render, {-7, -1, -1}, {-5, 1, 1}, render.debug_color(.GREEN))

  rot := linalg.quaternion_angle_axis_f32(t, {0, 1, 0})
  render.debug_cube(&engine.render, {-2, 1, 0}, rotation = rot, size = {1.5, 1.5, 1.5}, color = render.debug_color(.MAGENTA))

  r := 1.0 + 0.3 * math.sin(t * 2)
  render.debug_sphere(&engine.render, {2, 1, 0}, radius = r, color = render.debug_color(.CYAN))

  render.debug_circle(&engine.render, {6, 0.01, 0}, normal = {0, 1, 0}, radius = 1.5, color = render.debug_color(.YELLOW))
  render.debug_circle(&engine.render, {6, 2, 0}, normal = linalg.normalize([3]f32{1, 1, 0}), radius = 1.0, color = render.debug_color(.ORANGE))

  target := [3]f32{4 * math.cos(t), 3, 4 * math.sin(t)}
  render.debug_arrow(&engine.render, {0, 3, 0}, target, render.debug_color(.RED))
  render.debug_point(&engine.render, target, size = 0.3, color = white)

  trail_period :: 0.25
  trail_count_total := int(t / trail_period)
  if trail_count_total > 0 {
    last := f32(trail_count_total) * trail_period
    if last > elapsed - dt && last <= elapsed {
      angle := last * 1.5
      pos := [3]f32{5 * math.cos(angle), 0.5, 5 * math.sin(angle)}
      render.debug_sphere(&engine.render, pos, 0.25, render.debug_color(.GREEN), life = 3.0)
    }
  }

  // bypass_depth = renders over the real cube.
  render.debug_axes(&engine.render, {-6, 0, 0}, scale = 1.5, bypass_depth = true)
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

pre_render :: proc(engine: ^mjolnir.Engine) {
  render.debug_sphere(&engine.render, {0, 5, 0}, 0.4, render.debug_color(.CYAN))
}

// post_render_proc fires after record(); these segments appear next frame.
post_render :: proc(engine: ^mjolnir.Engine) {
  render.debug_sphere(&engine.render, {0, 6, 0}, 0.4, render.debug_color(.MAGENTA))
  render.debug_arrow(&engine.render, {0, 5, 0}, {0, 6, 0}, render.debug_color(.WHITE))
}
