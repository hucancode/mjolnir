package physics

import "core:fmt"
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
        create_static_body_sphere(&state.physics, 0.5, pos)
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
    destroy(&state.physics)
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
