package main

import "../../mjolnir"
import "../../mjolnir/animation"
import cont "../../mjolnir/containers"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/ease"
import "core:math/linalg"

CUBE_COUNT :: 50
ANIMATION_DURATION :: 8.0

cubes: [CUBE_COUNT]world.NodeHandle
spline: animation.Spline([3]f32)

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      engine.world.main_camera,
      {0, 10, 0},
      {0, 0, 0},
    )
    // Create figure-8/infinity symbol spline path
    // Parametric equations for figure-8: x = sin(t), y = 0, z = sin(2t)/2
    // Include duplicate first point at end for seamless looping
    CONTROL_POINTS :: 10
    spline = animation.spline_create([3]f32, CONTROL_POINTS)
    for i in 0 ..< CONTROL_POINTS {
      t := f32(i) * 2.0 * math.PI / f32(CONTROL_POINTS - 1)
      scale :: 5.0
      x := scale * math.sin(t)
      y := f32(0.0)
      z := scale * math.sin(2.0 * t) * 0.5
      spline.points[i] = [3]f32{x, y, z}
      spline.times[i] = f32(i) * ANIMATION_DURATION / f32(CONTROL_POINTS - 1)
    }
    if !animation.spline_validate(spline) {
      log.error("Spline validation failed!")
    }
    // Build arc-length table for uniform spatial sampling
    animation.spline_build_arc_table(&spline, 200)
    mat_handles := [?]world.MaterialHandle {
      world.get_builtin_material(&engine.world, .RED),
      world.get_builtin_material(&engine.world, .GREEN),
      world.get_builtin_material(&engine.world, .BLUE),
      world.get_builtin_material(&engine.world, .YELLOW),
      world.get_builtin_material(&engine.world, .CYAN),
      world.get_builtin_material(&engine.world, .MAGENTA),
      world.get_builtin_material(&engine.world, .WHITE),
      world.get_builtin_material(&engine.world, .GRAY),
      world.get_builtin_material(&engine.world, .BLACK),
    }
    cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
    for i in 0 ..< CUBE_COUNT {
      cubes[i] = world.spawn(
        &engine.world,
        {0, 0, 0},
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = mat_handles[i % len(mat_handles)],
        },
      )
      world.scale(&engine.world, cubes[i], 0.3)
    }
    // Add ground plane
    ground_mat := world.get_builtin_material(&engine.world, .GRAY)
    quad_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
    ground :=
      world.spawn(
        &engine.world,
        {0, 0, 0},
        attachment = world.MeshAttachment {
          handle = quad_mesh,
          material = ground_mat,
        },
      ) or_else {}
    world.scale(&engine.world, ground, 20.0)
    world.translate(&engine.world, ground, 0, -2, 0)
    light_handle :=
      world.spawn(
        &engine.world,
        {0, 10, 0},
        world.create_point_light_attachment({1.0, 1.0, 1.0, 1.0}, 20.0, true),
      ) or_else {}
    world.register_active_light(&engine.world, light_handle)
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    total_length := animation.spline_arc_length(spline)
    for i in 0 ..< CUBE_COUNT {
      offset := f32(i) / f32(CUBE_COUNT) * total_length
      elapsed := mjolnir.time_since_start(engine)
      current_s := math.mod_f32(
        elapsed * (total_length / ANIMATION_DURATION) + offset,
        total_length,
      )
      normalized := current_s / total_length
      tweened := ease.ease(.Quadratic_In_Out, normalized) * total_length
      pos := animation.spline_sample_uniform(spline, tweened)
      world.translate(&engine.world, cubes[i], pos.x, pos.y, pos.z)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-spline")
  animation.spline_destroy(&spline)
}
