package benchmark

import "../mjolnir/geometry"
import "../mjolnir/physics"
import "core:fmt"
import "core:math/linalg"
import "core:time"

@(private)
build_cube_grid :: proc(
  world: ^physics.World,
  dim_x, dim_y, dim_z: int,
  drop_height: f32 = 10.0,
) {
  half := f32(max(dim_x, dim_z)) * 1.5
  physics.create_static_body_box(
    world,
    {half, 0.5, half},
    {0, -0.5, 0},
    linalg.QUATERNIONF32_IDENTITY,
  )
  for x in 0 ..< dim_x {
    for y in 0 ..< dim_y {
      for z in 0 ..< dim_z {
        pos := [3]f32 {
          f32(x - dim_x / 2) * 2.0,
          drop_height + f32(y) * 2.0,
          f32(z - dim_z / 2) * 2.0,
        }
        h := physics.create_dynamic_body_box(
          world,
          {1, 1, 1},
          pos,
          linalg.QUATERNIONF32_IDENTITY,
          1.0,
        )
        if body, ok := physics.get_dynamic_body(world, h); ok {
          physics.set_box_inertia(body, {1, 1, 1})
        }
      }
    }
  }
}

@(private)
sample_phys_scene :: proc(
  b: ^Bench,
  scene_name: string,
  dim_x, dim_y, dim_z: int,
  warmup_steps: int,
  measure_steps: int,
  enable_parallel: bool,
) {
  world: physics.World
  physics.init(&world, {0, -9.81, 0}, enable_parallel)
  defer physics.destroy(&world)

  build_cube_grid(&world, dim_x, dim_y, dim_z)

  dt: f32 = 1.0 / 60.0
  for _ in 0 ..< warmup_steps {
    physics.step(&world, dt)
  }

  total_ms := make([]f64, measure_steps, context.temp_allocator)
  broadphase_ms := make([]f64, measure_steps, context.temp_allocator)
  solver_ms := make([]f64, measure_steps, context.temp_allocator)
  prepare_ms := make([]f64, measure_steps, context.temp_allocator)
  bvh_ms := make([]f64, measure_steps, context.temp_allocator)
  awake_count: int = 0
  contact_count: int = 0
  for i in 0 ..< measure_steps {
    physics.step(&world, dt)
    p := world.last_perf
    total_ms[i] = f64(p.total_ms)
    broadphase_ms[i] = f64(p.broadphase_ms)
    solver_ms[i] = f64(p.solver_ms)
    prepare_ms[i] = f64(p.prepare_ms)
    bvh_ms[i] = f64(p.bvh_build_ms)
    if i == measure_steps - 1 {
      awake_count = p.awake_body_count
      contact_count = p.dynamic_contact_count + p.static_contact_count
    }
  }
  summarize(b, fmt.tprintf("physics/%s/step_total", scene_name), "ms", total_ms)
  summarize(
    b,
    fmt.tprintf("physics/%s/broadphase", scene_name),
    "ms",
    broadphase_ms,
  )
  summarize(b, fmt.tprintf("physics/%s/solver", scene_name), "ms", solver_ms)
  summarize(b, fmt.tprintf("physics/%s/prepare", scene_name), "ms", prepare_ms)
  summarize(b, fmt.tprintf("physics/%s/bvh_build", scene_name), "ms", bvh_ms)
  emit(
    b,
    fmt.tprintf("physics/%s/awake_at_end", scene_name),
    "bodies",
    f64(awake_count),
    fmt.tprintf("dim=%dx%dx%d", dim_x, dim_y, dim_z),
  )
  emit(
    b,
    fmt.tprintf("physics/%s/contacts_at_end", scene_name),
    "contacts",
    f64(contact_count),
    "",
  )
}

bench_physics_simulation :: proc(b: ^Bench) {
  sample_phys_scene(b, "stack_5x4x5",     5,  4, 5, 30, 200, false)
  sample_phys_scene(b, "stack_8x4x8",     8,  4, 8, 30, 200, false)
  sample_phys_scene(b, "grid_10x1x10",   10,  1, 10, 30, 200, false)
}

bench_physics_raycast :: proc(b: ^Bench) {
  world: physics.World
  physics.init(&world, {0, -9.81, 0}, false)
  defer physics.destroy(&world)

  grid_size := 50
  for x in 0 ..< grid_size {
    for z in 0 ..< grid_size {
      world_x := (f32(x) - f32(grid_size) * 0.5) * 1.0
      world_z := (f32(z) - f32(grid_size) * 0.5) * 1.0
      physics.create_static_body_sphere(
        &world,
        0.5,
        {world_x, 0.5, world_z},
        linalg.QUATERNIONF32_IDENTITY,
      )
    }
  }
  physics.step(&world, 0.0)

  num_rays :: 10000
  rays: [num_rays]geometry.Ray
  for i in 0 ..< num_rays {
    x := (f32(i % 100) - 50.0) * 0.5
    z := (f32(i / 100) - 50.0) * 0.5
    rays[i] = geometry.Ray {
      origin    = {x, 10, z},
      direction = {0, -1, 0},
    }
  }

  iters := 10
  per_iter_ms := make([]f64, iters, context.temp_allocator)
  hits := 0
  for it in 0 ..< iters {
    t := time.tick_now()
    for r in rays {
      hit := physics.raycast(&world, r, 100.0)
      if hit.hit do hits += 1
    }
    per_iter_ms[it] = f64(time.tick_since(t)) / f64(time.Millisecond)
  }
  summarize(b, "physics/raycast/10k_rays_total", "ms", per_iter_ms)
  median_ms := per_iter_ms[len(per_iter_ms) / 2]
  rays_per_ms := f64(num_rays) / median_ms
  emit(
    b,
    "physics/raycast/throughput",
    "rays_per_ms",
    rays_per_ms,
    fmt.tprintf("hits=%d", hits / iters),
  )
}
