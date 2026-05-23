package main

import "../../mjolnir"
import "../../mjolnir/animation"
import "core:log"
import "core:math"
import "core:math/ease"

CUBE_COUNT :: 50
ANIMATION_DURATION :: 8.0

cubes: [CUBE_COUNT]mjolnir.NodeHandle
spline: animation.Spline([3]f32)

main :: proc() {
  mjolnir.run_app({title = "Spline", setup = setup, update = update})
  animation.spline_destroy(&spline)
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {0, 10, 0}, {0, 0, 0})

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

  mats := [?]mjolnir.MaterialHandle{
    mjolnir.builtin_material(engine, .RED), mjolnir.builtin_material(engine, .GREEN),
    mjolnir.builtin_material(engine, .BLUE), mjolnir.builtin_material(engine, .YELLOW),
    mjolnir.builtin_material(engine, .CYAN), mjolnir.builtin_material(engine, .MAGENTA),
    mjolnir.builtin_material(engine, .WHITE), mjolnir.builtin_material(engine, .GRAY),
    mjolnir.builtin_material(engine, .BLACK),
  }
  cube := mjolnir.builtin_mesh(engine, .CUBE)
  for i in 0 ..< CUBE_COUNT {
    cubes[i] = mjolnir.spawn(engine, {0, 0, 0}, mjolnir.MeshAttachment{handle = cube, material = mats[i % len(mats)]})
    mjolnir.scale(engine, cubes[i], 0.3)
  }
  ground := mjolnir.spawn(engine, {0, 0, 0}, mjolnir.MeshAttachment{handle = mjolnir.builtin_mesh(engine, .QUAD_XZ), material = mjolnir.builtin_material(engine, .GRAY)})
  mjolnir.scale(engine, ground, 20.0)
  mjolnir.translate(engine, ground, 0, -2, 0)
  mjolnir.spawn_light_point(engine, {0, 10, 0}, {1, 1, 1, 1}, 20.0, true)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  total_length := animation.spline_arc_length(spline)
  for i in 0 ..< CUBE_COUNT {
    offset := f32(i) / f32(CUBE_COUNT) * total_length
    elapsed := mjolnir.time_since_start(engine)
    current_s := math.mod_f32(elapsed * (total_length / ANIMATION_DURATION) + offset, total_length)
    normalized := current_s / total_length
    tweened := ease.ease(.Quadratic_In_Out, normalized) * total_length
    mjolnir.translate(engine, cubes[i], animation.spline_sample_uniform(spline, tweened))
  }
}
