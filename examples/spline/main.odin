package main

import "../../mjolnir"
import "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/ease"
import "core:math/linalg"

CUBE_COUNT :: 50
ANIMATION_DURATION :: 8.0

cubes: [CUBE_COUNT]mjolnir.NodeHandle
spline: animation.Spline([3]f32)

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    if camera := mjolnir.get_main_camera(engine); camera != nil {
      mjolnir.camera_look_at(camera, {0, 10, 0}, {0, 0, 0})
      mjolnir.sync_active_camera_controller(engine)
    }
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
    mat_handles := [?]mjolnir.MaterialHandle {
      mjolnir.get_builtin_material(engine, .RED),
      mjolnir.get_builtin_material(engine, .GREEN),
      mjolnir.get_builtin_material(engine, .BLUE),
      mjolnir.get_builtin_material(engine, .YELLOW),
      mjolnir.get_builtin_material(engine, .CYAN),
      mjolnir.get_builtin_material(engine, .MAGENTA),
      mjolnir.get_builtin_material(engine, .WHITE),
      mjolnir.get_builtin_material(engine, .GRAY),
      mjolnir.get_builtin_material(engine, .BLACK),
    }
    cube_mesh := mjolnir.get_builtin_mesh(engine, .CUBE)
    for i in 0 ..< CUBE_COUNT {
      cubes[i] = mjolnir.spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = mat_handles[i % len(mat_handles)],
        },
      )
      mjolnir.scale(engine, cubes[i], 0.3)
    }
    // Add ground plane
    ground_mat := mjolnir.get_builtin_material(engine, .GRAY)
    quad_mesh := mjolnir.get_builtin_mesh(engine, .QUAD_XZ)
    ground := mjolnir.spawn(
      engine,
      attachment = world.MeshAttachment {
        handle = quad_mesh,
        material = ground_mat,
      },
    )
    mjolnir.scale(engine, ground, 20.0)
    mjolnir.translate(engine, ground, 0, -2, 0)
    mjolnir.spawn_point_light(
      engine,
      {1.0, 1.0, 1.0, 1.0},
      20.0,
      position = {0, 10, 0},
    )
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
      mjolnir.translate(engine, cubes[i], pos.x, pos.y, pos.z)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-spline")
  animation.spline_destroy(&spline)
}
