package main

import "../../mjolnir"
import "../../mjolnir/animation"
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
  world.main_camera_look_at(&engine.world, {0, 10, 0}, {0, 0, 0})

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

  mats := [?]world.MaterialHandle{
    world.get_builtin_material(&engine.world, .RED), world.get_builtin_material(&engine.world, .GREEN),
    world.get_builtin_material(&engine.world, .BLUE), world.get_builtin_material(&engine.world, .YELLOW),
    world.get_builtin_material(&engine.world, .CYAN), world.get_builtin_material(&engine.world, .MAGENTA),
    world.get_builtin_material(&engine.world, .WHITE), world.get_builtin_material(&engine.world, .GRAY),
    world.get_builtin_material(&engine.world, .BLACK),
  }
  cube := world.get_builtin_mesh(&engine.world, .CUBE)
  for i in 0 ..< CUBE_COUNT {
    cubes[i] = world.spawn(&engine.world, {0, 0, 0}, world.MeshAttachment{handle = cube, material = mats[i % len(mats)]})
    world.scale(&engine.world, cubes[i], 0.3)
  }
  world.spawn_ground(&engine.world, 20.0, position = {0, -2, 0})
  world.spawn_light_point(&engine.world, {0, 10, 0}, {1, 1, 1, 1}, 20.0, true)
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
