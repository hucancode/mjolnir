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

cubes: [CUBE_COUNT]resources.Handle
spline: animation.Spline([3]f32)

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    using mjolnir
    // Setup camera
    if camera := get_main_camera(engine); camera != nil {
      resources.camera_look_at(camera, {0, 10, 0}, {0, 0, 0})
      world.camera_controller_sync(&engine.orbit_controller, camera)
    }
    // Create figure-8/infinity symbol spline path
    // Parametric equations for figure-8: x = sin(t), y = 0, z = sin(2t)/2
    // Include duplicate first point at end for seamless looping
    CONTROL_POINTS :: 33
    spline = animation.spline_create([3]f32, CONTROL_POINTS)
    for i in 0 ..< CONTROL_POINTS {
      t := f32(i) * 2.0 * math.PI / f32(CONTROL_POINTS - 1)
      // Figure-8 pattern (lemniscate)
      scale :: 5.0
      x := scale * math.sin(t)
      y := f32(0.0)
      z := scale * math.sin(2.0 * t) * 0.5
      spline.points[i] = [3]f32{x, y, z}
      spline.times[i] = f32(i) * ANIMATION_DURATION / f32(CONTROL_POINTS - 1)
    }
    // Verify spline is valid
    if !animation.spline_validate(spline) {
      log.error("Spline validation failed!")
    }
    // Create cubes with different colors
    mat_handles := [?]resources.Handle {
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
        world.MeshAttachment{handle = cube_mesh, material = mat_handles[i%len(mat_handles)]},
      )
      scale_handle(engine, cubes[i], 0.3)
    }
    // Add ground plane
    ground_mat := engine.rm.builtin_materials[resources.Color.GRAY]
    quad_mesh := engine.rm.builtin_meshes[resources.Primitive.QUAD]
    ground := spawn(engine, world.MeshAttachment{handle = quad_mesh, material = ground_mat})
    scale_handle(engine, ground, 20.0)
    translate(engine, ground, 0, -2, 0)
    spawn_point_light(engine, {1.0, 1.0, 1.0, 1.0}, 20.0, position = {0, 10, 0})
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    using mjolnir
    for i in 0 ..< CUBE_COUNT {
      offset := f32(i) / f32(CUBE_COUNT) * ANIMATION_DURATION
      offset_time := math.mod_f32(time_since_start(engine) + offset, ANIMATION_DURATION)
      normalized := offset_time / ANIMATION_DURATION
      tweened := animation.ease(normalized, .QuadInOut)
      sample_time := tweened * ANIMATION_DURATION
      pos := animation.spline_sample(spline, sample_time)
      translate(engine, cubes[i], pos.x, pos.y, pos.z)
    }
  }
  mjolnir.run(engine, 800, 600, "visual-spline")
  animation.spline_destroy(&spline)
}
