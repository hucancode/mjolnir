package main

import "../../mjolnir"
import "../../mjolnir/animation"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/ease"

CUBE_COUNT :: 50
ANIMATION_DURATION :: 8.0

cubes: [CUBE_COUNT]world.NodeHandle
spline: animation.Spline([3]f32)

main :: proc() {
  mjolnir.run_app({title = "Spline", setup = setup, update = update})
  animation.spline_destroy(&spline)
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {0, 10, 0}, {0, 0, 0})

  CONTROL_POINTS :: 10
  spline = animation.spline_create([3]f32, CONTROL_POINTS)
  for i in 0 ..< CONTROL_POINTS {
    t := f32(i) * 2.0 * math.PI / f32(CONTROL_POINTS - 1)
    scale :: 5.0
    spline.points[i] = {scale * math.sin(t), 0, scale * math.sin(2.0 * t) * 0.5}
    spline.times[i] = f32(i) * ANIMATION_DURATION / f32(CONTROL_POINTS - 1)
  }
  if !animation.spline_validate(spline) do log.error("Spline validation failed!")
  animation.spline_build_arc_table(&spline, 200)

  mats := [?]render.MaterialHandle{
    render.get_builtin_material(&engine.render, .RED), render.get_builtin_material(&engine.render, .GREEN),
    render.get_builtin_material(&engine.render, .BLUE), render.get_builtin_material(&engine.render, .YELLOW),
    render.get_builtin_material(&engine.render, .CYAN), render.get_builtin_material(&engine.render, .MAGENTA),
    render.get_builtin_material(&engine.render, .WHITE), render.get_builtin_material(&engine.render, .GRAY),
    render.get_builtin_material(&engine.render, .BLACK),
  }
  cube := render.get_builtin_mesh(&engine.render, .CUBE)
  for i in 0 ..< CUBE_COUNT {
    cubes[i] = mjolnir.spawn(engine, {0, 0, 0}, render.MeshAttachment{handle = cube, material = mats[i % len(mats)]})
    world.scale(&engine.world, cubes[i], 0.3)
  }
  mjolnir.spawn_ground(engine, 20.0, position = {0, -2, 0})
  mjolnir.spawn(engine, {0, 10, 0}, render.point_light_attachment({1, 1, 1, 1}, 20.0, true))
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  total_length := animation.spline_arc_length(spline)
  for i in 0 ..< CUBE_COUNT {
    offset := f32(i) / f32(CUBE_COUNT) * total_length
    elapsed := mjolnir.time_since_start(engine)
    current_s := math.mod_f32(elapsed * (total_length / ANIMATION_DURATION) + offset, total_length)
    normalized := current_s / total_length
    tweened := ease.ease(.Quadratic_In_Out, normalized) * total_length
    world.translate(&engine.world, cubes[i], animation.spline_sample_uniform(spline, tweened))
  }
}
