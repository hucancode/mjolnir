package physics

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"
import "../geometry"

@(test)
benchmark_physics_raycast :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)

  Physics_Raycast_State :: struct {
    physics:     World,
    rays:        []geometry.Ray,
    current_ray: int,
    hit_count:   int,
  }

  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(Physics_Raycast_State)
    init(&state.physics, enable_parallel = false)
    // Spawn a 50x50 grid of bodies (2500 total)
    grid_size := 50
    spacing: f32 = 1.0
    for x in 0 ..< grid_size {
      for z in 0 ..< grid_size {
        world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
        world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
        pos := [3]f32{world_x, 0.5, world_z}
        create_static_body(&state.physics, position = pos, collider = SphereCollider{radius = 0.5})
      }
    }
    step(&state.physics, 0.0)
    // Generate rays
    num_rays := 10000
    state.rays = make([]geometry.Ray, num_rays)
    for i in 0 ..< num_rays {
      // Rays shooting down from random positions above the grid
      x := (f32(i % 100) - 50.0) * 0.5
      z := (f32(i / 100) - 50.0) * 0.5
      state.rays[i] = geometry.Ray {
        origin    = {x, 10, z},
        direction = {0, -1, 0},
      }
    }

    state.current_ray = 0
    options.input = slice.bytes_from_ptr(state, size_of(Physics_Raycast_State))
    options.bytes = size_of(geometry.Ray) + size_of(RayHit)
    return nil
  }

  bench_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Physics_Raycast_State)raw_data(options.input)
    for _ in 0 ..< options.rounds {
      ray := state.rays[state.current_ray]
      state.current_ray = (state.current_ray + 1) % len(state.rays)
      hit := raycast(&state.physics, ray, 100.0)
      if hit.hit {
        state.hit_count += 1
      }
      options.processed += size_of(geometry.Ray)
    }
    return nil
  }

  teardown_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := cast(^Physics_Raycast_State)raw_data(options.input)
    shutdown(&state.physics)
    delete(state.rays)
    free(state)
    return nil
  }

  options := &time.Benchmark_Options {
    setup = setup_proc,
    bench = bench_proc,
    teardown = teardown_proc,
    rounds = 1000,
  }

  err := time.benchmark(options)
  state := cast(^Physics_Raycast_State)raw_data(options.input)
  hit_rate := f32(state.hit_count) / f32(options.rounds) * 100
  log.infof(
    "Physics raycast: %d casts in %v (%.2f MB/s) | %.2f μs/cast | %d hits (%.1f%%)",
    options.rounds,
    options.duration,
    options.megabytes_per_second,
    time.duration_microseconds(options.duration) / f64(options.rounds),
    state.hit_count,
    hit_rate,
  )
}

@(private = "file")
near :: proc(a, b: [3]f32, eps: f32 = 1e-3) -> bool {
  return linalg.length(a - b) < eps
}

@(test)
test_raycast_rotated_box :: proc(t: ^testing.T) {
  // Unit cube rotated 45 deg about Y: its corner points at -X, 0.707 from center
  rot := linalg.quaternion_angle_axis_f32(math.PI / 4, {0, 1, 0})
  box: Collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}}
  ray := geometry.Ray{origin = {-5, 0.2, 0.2}, direction = {1, 0, 0}}
  tt, n, hit := raycast_collider(ray, &box, {}, rot, 100)
  testing.expect(t, hit)
  // Face x' = -0.5 in local frame: hit at x = -(0.7071 - 0.2) = -0.5071
  testing.expectf(t, math.abs(tt - 4.4929) < 1e-3, "t = %v", tt)
  testing.expectf(t, near(n, {-0.7071, 0, 0.7071}), "normal = %v", n)
  // Line x - z = 1 crosses the world AABB corner but misses the rotated box
  ray = geometry.Ray{origin = {-4.5, 0, -5.5}, direction = linalg.normalize([3]f32{1, 0, 1})}
  _, _, hit = raycast_collider(ray, &box, {}, rot, 100)
  testing.expect(t, !hit)
}

@(test)
test_raycast_aligned_box_normals :: proc(t: ^testing.T) {
  box: Collider = BoxCollider{half_extents = {1, 2, 3}}
  pos := [3]f32{10, 0, 0}
  tt, n, hit := raycast_collider({origin = {10, 10, 0}, direction = {0, -1, 0}}, &box, pos, linalg.QUATERNIONF32_IDENTITY, 100)
  testing.expect(t, hit)
  testing.expect(t, math.abs(tt - 8) < 1e-4)
  testing.expect(t, near(n, {0, 1, 0}))
  tt, n, hit = raycast_collider({origin = {10, 0, -10}, direction = {0, 0, 1}}, &box, pos, linalg.QUATERNIONF32_IDENTITY, 100)
  testing.expect(t, hit && math.abs(tt - 7) < 1e-4)
  testing.expect(t, near(n, {0, 0, -1}))
  _, _, hit = raycast_collider({origin = {10, 0, -10}, direction = {0, 0, 1}}, &box, pos, linalg.QUATERNIONF32_IDENTITY, 5)
  testing.expect(t, !hit)
}

@(test)
test_raycast_cylinder :: proc(t: ^testing.T) {
  cyl: Collider = CylinderCollider{radius = 1, height = 2}
  id := linalg.QUATERNIONF32_IDENTITY
  // Side wall
  tt, n, hit := raycast_collider({origin = {-5, 0, 0}, direction = {1, 0, 0}}, &cyl, {}, id, 100)
  testing.expect(t, hit && math.abs(tt - 4) < 1e-4)
  testing.expect(t, near(n, {-1, 0, 0}))
  // Top cap
  tt, n, hit = raycast_collider({origin = {0.5, 5, 0}, direction = {0, -1, 0}}, &cyl, {}, id, 100)
  testing.expect(t, hit && math.abs(tt - 4) < 1e-4)
  testing.expect(t, near(n, {0, 1, 0}))
  // Passes the AABB corner but misses the round wall
  _, _, hit = raycast_collider({origin = {-5, 0, 0.95}, direction = {1, 0, 1}}, &cyl, {}, id, 100)
  testing.expect(t, !hit)
  // Lying on its side (axis along X): the wall faces +Y
  rot := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1})
  tt, n, hit = raycast_collider({origin = {0, 5, 0}, direction = {0, -1, 0}}, &cyl, {}, rot, 100)
  testing.expect(t, hit && math.abs(tt - 4) < 1e-4)
  testing.expectf(t, near(n, {0, 1, 0}), "normal = %v", n)
}

@(test)
test_raycast_fan :: proc(t: ^testing.T) {
  // 90 deg sector facing +Z
  fan: Collider = FanCollider{radius = 2, height = 1, angle = math.PI / 2}
  id := linalg.QUATERNIONF32_IDENTITY
  // Hits the curved wall straight ahead
  tt, n, hit := raycast_collider({origin = {0, 0, 5}, direction = {0, 0, -1}}, &fan, {}, id, 100)
  testing.expect(t, hit && math.abs(tt - 3) < 1e-4)
  testing.expect(t, near(n, {0, 0, 1}))
  // Behind the fan: misses
  _, _, hit = raycast_collider({origin = {-5, 0, -0.5}, direction = {1, 0, 0}}, &fan, {}, id, 100)
  testing.expect(t, !hit)
  // Through the side plane at +45 deg
  tt, n, hit = raycast_collider({origin = {5, 0, 0.5}, direction = {-1, 0, 0}}, &fan, {}, id, 100)
  testing.expect(t, hit)
  testing.expectf(t, math.abs(tt - 4.5) < 1e-3, "t = %v", tt)
  testing.expectf(t, near(n, {0.7071, 0, -0.7071}), "normal = %v", n)
}

@(test)
test_set_body_pose_updates_broadphase :: proc(t: ^testing.T) {
  w: World
  init(&w, enable_parallel = false)
  defer shutdown(&w)
  h := create_static_body(&w, position = {0, 0, 0}, collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}})
  step(&w, 1.0 / 60.0)
  ray := geometry.Ray{origin = {10, 5, 0}, direction = {0, -1, 0}}
  testing.expect(t, !raycast(&w, ray).hit)
  set_body_pose(&w, h, [3]f32{10, 0, 0}, linalg.QUATERNIONF32_IDENTITY)
  hit := raycast(&w, ray)
  testing.expect(t, hit.hit && math.abs(hit.t - 4.5) < 1e-4)
  set_body_collider(&w, h, BoxCollider{half_extents = {1, 2, 1}})
  hit = raycast(&w, ray)
  testing.expect(t, hit.hit && math.abs(hit.t - 3) < 1e-4)
}
