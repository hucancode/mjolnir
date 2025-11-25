package main

import "../../../mjolnir"
import "../../../mjolnir/animation"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

CUBE_COUNT :: 50
ANIMATION_DURATION :: 8.0

cubes: [CUBE_COUNT]resources.NodeHandle
spline: animation.Spline([3]f32)

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    using mjolnir
    // Setup camera
    if camera := get_main_camera(engine); camera != nil {
      camera_look_at(camera, {0, 10, 0}, {0, 0, 0})
      sync_active_camera_controller(engine)
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
    mat_handles := [?]resources.MaterialHandle {
      engine.rm.builtin_materials[resources.Color.RED],
      engine.rm.builtin_materials[resources.Color.GREEN],
      engine.rm.builtin_materials[resources.Color.BLUE],
      engine.rm.builtin_materials[resources.Color.YELLOW],
      engine.rm.builtin_materials[resources.Color.CYAN],
      engine.rm.builtin_materials[resources.Color.MAGENTA],
      engine.rm.builtin_materials[resources.Color.WHITE],
      engine.rm.builtin_materials[resources.Color.GRAY],
      engine.rm.builtin_materials[resources.Color.BLACK],
    }
    cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
    for i in 0 ..< CUBE_COUNT {
      cubes[i] = spawn(
        engine,
        attachment = world.MeshAttachment {
          handle = cube_mesh,
          material = mat_handles[i % len(mat_handles)],
        },
      )
      scale(engine, cubes[i], 0.3)
    }
    // Add ground plane
    ground_mat := engine.rm.builtin_materials[resources.Color.GRAY]
    quad_mesh := engine.rm.builtin_meshes[resources.Primitive.QUAD]
    ground := spawn(
      engine,
      attachment = world.MeshAttachment {
        handle = quad_mesh,
        material = ground_mat,
      },
    )
    scale(engine, ground, 20.0)
    translate(engine, ground, 0, -2, 0)
    spawn_point_light(
      engine,
      {1.0, 1.0, 1.0, 1.0},
      20.0,
      position = {0, 10, 0},
    )
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    using mjolnir
    total_length := animation.spline_arc_length(spline)
    for i in 0 ..< CUBE_COUNT {
      offset := f32(i) / f32(CUBE_COUNT) * total_length
      elapsed := time_since_start(engine)
      current_s := math.mod_f32(
        elapsed * (total_length / ANIMATION_DURATION) + offset,
        total_length,
      )
      normalized := current_s / total_length
      tweened := animation.sample(normalized, 0, total_length, .QuadInOut)
      pos := animation.spline_sample_uniform(spline, tweened)
      translate(engine, cubes[i], pos.x, pos.y, pos.z)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-spline")
  animation.spline_destroy(&spline)
}
