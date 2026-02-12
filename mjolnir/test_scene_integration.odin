package mjolnir

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"
import "geometry"
import "physics"
import "world"

@(test)
benchmark_physics_raycast :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second)

  Physics_Raycast_State :: struct {
    physics:     physics.World,
    w:           world.World,
    rays:        []geometry.Ray,
    current_ray: int,
    hit_count:   int,
  }

  setup_proc :: proc(
    options: ^time.Benchmark_Options,
    allocator := context.allocator,
  ) -> time.Benchmark_Error {
    state := new(Physics_Raycast_State)

    // Initialize physics and world
    physics.init(&state.physics, enable_parallel = false)
    world.init(&state.w)

    // Spawn a 50x50 grid of bodies (2500 total)
    grid_size := 50
    spacing: f32 = 1.0
    for x in 0 ..< grid_size {
      for z in 0 ..< grid_size {
        world_x := (f32(x) - f32(grid_size) * 0.5) * spacing
        world_z := (f32(z) - f32(grid_size) * 0.5) * spacing
        pos := [3]f32{world_x, 0.5, world_z}
        world.spawn(&state.w, pos)
        physics.create_static_body_sphere(&state.physics, 0.5, pos)
      }
    }
    physics.step(&state.physics, 0.0)
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
    options.bytes = size_of(geometry.Ray) + size_of(physics.RayHit)
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
      hit := physics.raycast(&state.physics, ray, 100.0)
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
    physics.destroy(&state.physics)
    world.shutdown(&state.w)
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

matrix4_almost_equal :: proc(
  t: ^testing.T,
  actual, expected: matrix[4, 4]f32,
) {
  for i in 0 ..< 4 {
    for j in 0 ..< 4 {
      delta := math.abs(actual[i, j] - expected[i, j])
      // Use a more lenient epsilon for floating point comparisons
      testing.expect(
        t,
        delta < 0.01,
        fmt.tprintf(
          "Matrix difference at [%d,%d], actual: %v . expected: %v",
          i,
          j,
          actual,
          expected,
        ),
      )
    }
  }
}

@(test)
test_node_translate :: proc(t: ^testing.T) {
  w: world.World
  world.init(&w)
  defer world.shutdown(&w)
  parent_handle, parent_ok := world.spawn(&w, {1, 2, 3})
  testing.expectf(t, parent_ok, "failed to spawn parent node")
  child, ok := world.spawn_child(&w, parent_handle)
  child_ptr := world.get_node(&w, child)
  testing.expectf(t, ok, "failed to spawn child node")
  world.translate(&w, child, 4, 5, 6)
  world.begin_frame(&w)
  actual := child_ptr.transform.world_matrix
  expected := matrix[4, 4]f32{
    1.0, 0.0, 0.0, 5.0,
    0.0, 1.0, 0.0, 7.0,
    0.0, 0.0, 1.0, 9.0,
    0.0, 0.0, 0.0, 1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_rotate :: proc(t: ^testing.T) {
  w: world.World
  world.init(&w)
  defer world.shutdown(&w)
  child, ok := world.spawn(&w)
  child_ptr := world.get_node(&w, child)
  testing.expectf(t, ok, "failed to spawn node")
  world.rotate(&w, child, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  world.translate(&w, child, 1, 0, 0)
  world.begin_frame(&w)
  actual := child_ptr.transform.world_matrix
  expected := matrix[4, 4]f32{
    0.0, 0.0, 1.0, 1.0,
    0.0, 1.0, 0.0, 0.0,
    -1.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_scale :: proc(t: ^testing.T) {
  w: world.World
  world.init(&w)
  defer world.shutdown(&w)
  parent_handle, parent_ok := world.spawn(&w, {1, 2, 3})
  testing.expectf(t, parent_ok, "failed to spawn parent node")
  child, child_ok := world.spawn_child(&w, parent_handle)
  child_ptr := world.get_node(&w, child)
  testing.expectf(t, child_ok, "failed to spawn child node")
  world.scale_xyz(&w, child, 5, 6, 7)
  world.begin_frame(&w)
  actual := child_ptr.transform.world_matrix
  expected := matrix[4, 4]f32{
    5.0, 0.0, 0.0, 1.0,
    0.0, 6.0, 0.0, 2.0,
    0.0, 0.0, 7.0, 3.0,
    0.0, 0.0, 0.0, 1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_combined_transform :: proc(t: ^testing.T) {
  w: world.World
  world.init(&w)
  defer world.shutdown(&w)
  node, node_ok := world.spawn(&w)
  node_ptr := world.get_node(&w, node)
  testing.expectf(t, node_ok, "failed to spawn node")
  world.scale(&w, node, 2)
  world.rotate(&w, node, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  world.translate(&w, node, 3, 4, 5)
  world.begin_frame(&w)
  actual := node_ptr.transform.world_matrix
  // Expected matrix after applying scale, rotation, and translation
  // Scale by 2, then rotate 90 degree around Y, then translate by (3,4,5)
  expected := matrix[4, 4]f32{
    0.0, 0.0, 2.0, 3.0,
    0.0, 2.0, 0.0, 4.0,
    -2.0, 0.0, 0.0, 5.0,
    0.0, 0.0, 0.0, 1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_chain_transform :: proc(t: ^testing.T) {
  w: world.World
  world.init(&w)
  defer world.shutdown(&w)
  // Create a 4-node chain
  node1_handle, node1_ok := world.spawn(&w)
  testing.expectf(t, node1_ok, "failed to spawn node1")
  node2_handle, node2_ok := world.spawn_child(&w, node1_handle)
  testing.expectf(t, node2_ok, "failed to spawn node2")
  node3_handle, node3_ok := world.spawn_child(&w, node2_handle)
  node3 := world.get_node(&w, node3_handle)
  testing.expectf(t, node3_ok, "failed to spawn node3")
  world.translate(&w, node1_handle, x = 1)
  world.rotate(&w, node2_handle, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  world.scale(&w, node3_handle, 2)
  world.begin_frame(&w)
  // The transforms should cascade:
  // node1: translate(1,0,0)
  // node2: translate(1,0,0) * rotate_y(90°)
  // node3: translate(1,0,0) * rotate_y(90°) * scale(2)
  actual := node3.transform.world_matrix
  // Note: The node chain transforms in this order:
  // 1. Start at origin
  // 2. Translate by (1,0,0)
  // 3. Rotate 90° around Y axis (makes Z become X, and X become -Z)
  // 4. Scale by 2 in all dimensions
  expected := matrix[4, 4]f32{
    0.0, 0.0, 2.0, 1.0,
    0.0, 2.0, 0.0, 0.0,
    -2.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

create_scene :: proc(scene: ^world.World, max_node: int, max_depth: int) {
  target_nodes := max_node
  if scene.nodes.capacity > 0 {
    target_nodes = min(target_nodes, int(scene.nodes.capacity))
  }
  if max_depth <= 0 || target_nodes <= 0 do return
  QueueEntry :: struct {
    handle: world.NodeHandle,
    depth:  int,
  }
  queue: [dynamic]QueueEntry
  defer delete(queue)
  entry := QueueEntry{scene.root, 0}
  append(&queue, entry)
  n := 0
  for len(queue) > 0 && len(scene.nodes.entries) < target_nodes {
    current := pop_front(&queue)
    if current.depth < max_depth {
      child_handle := world.spawn_child(scene, current.handle) or_continue
      world.translate(scene, child_handle, f32(n % 10) * 0.1, 0, 0)
      world.rotate(
        scene,
        child_handle,
        f32(n) * 0.01,
        linalg.VECTOR3F32_Y_AXIS,
      )
      append(&queue, QueueEntry{child_handle, current.depth + 1})
    } else {
      child_handle := world.spawn(scene) or_continue
      world.translate(scene, child_handle, f32(n % 10) * 0.1, 0, 0)
      world.rotate(
        scene,
        child_handle,
        f32(n) * 0.01,
        linalg.VECTOR3F32_Y_AXIS,
      )
      append(&queue, QueueEntry{child_handle, 1})
    }
    n += 1
  }
  log.infof(
    "Generated a scene with %d nodes and max depth %d",
    len(scene.nodes.entries),
    max_depth,
  )
}

traverse_scene_benchmark :: proc(
  options: ^time.Benchmark_Options,
  allocator := context.allocator,
) -> time.Benchmark_Error {
  scene := cast(^world.World)(raw_data(options.input))
  // simulate an use case that traverse the scene and count the number of lights and meshes
  Context :: struct {
    light_count: u32,
    mesh_count:  u32,
  }
  for _ in 0 ..< options.rounds {
    ctx: Context
    world.traverse(scene)
    options.processed += size_of(world.Node) * len(scene.nodes.entries)
  }
  return nil
}

teardown_scene :: proc(
  options: ^time.Benchmark_Options,
  allocator := context.allocator,
) -> time.Benchmark_Error {
  scene := cast(^world.World)(raw_data(options.input))
  world.shutdown(scene)
  free(scene, allocator)
  return nil
}

@(test)
benchmark_deep_scene_traversal :: proc(t: ^testing.T) {
  N :: 1000_000
  ROUND :: 5
  options := &time.Benchmark_Options {
    rounds = ROUND,
    bytes = size_of(world.Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(world.World)
      world.init(scene)
      create_scene(scene, N, N)
      options.input = slice.bytes_from_ptr(scene, size_of(^world.World))
      return nil
    },
    bench = traverse_scene_benchmark,
    teardown = teardown_scene,
  }
  err := time.benchmark(options)
  if err != nil {
    testing.fail_now(t, fmt.tprintf("benchmark failed: %v", err))
  }
  log.infof(
    "Traversed scene (%d nodes, max depth %d): %v (%.2f MB/s)",
    N,
    N,
    options.duration,
    options.megabytes_per_second,
  )
}

@(test)
benchmark_flat_scene_traversal :: proc(t: ^testing.T) {
  N :: 1000_000
  ROUND :: 5
  options := &time.Benchmark_Options {
    rounds = ROUND,
    bytes = size_of(world.Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(world.World)
      world.init(scene)
      create_scene(scene, N, 1)
      options.input = slice.bytes_from_ptr(scene, size_of(^world.World))
      return nil
    },
    bench = traverse_scene_benchmark,
    teardown = teardown_scene,
  }
  err := time.benchmark(options)
  if err != nil {
    testing.fail_now(t, fmt.tprintf("benchmark failed: %v", err))
  }
  log.infof(
    "Traversed scene (%d nodes, depth 1): %v (%.2f MB/s)",
    N,
    options.duration,
    options.megabytes_per_second,
  )
}

@(test)
benchmark_balanced_scene_traversal :: proc(t: ^testing.T) {
  N :: 1000_000
  MAX_DEPTH :: 1000
  ROUND :: 5
  options := &time.Benchmark_Options {
    rounds = ROUND,
    bytes = size_of(world.Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(world.World)
      world.init(scene)
      create_scene(scene, N, MAX_DEPTH)
      options.input = slice.bytes_from_ptr(scene, size_of(^world.World))
      return nil
    },
    bench = traverse_scene_benchmark,
    teardown = teardown_scene,
  }
  err := time.benchmark(options)
  if err != nil {
    testing.fail_now(t, fmt.tprintf("benchmark failed: %v", err))
  }
  log.infof(
    "Traversed scene (%d nodes, max depth %d): %v (%.2f MB/s)",
    N,
    MAX_DEPTH,
    options.duration,
    options.megabytes_per_second,
  )
}

@(test)
test_scene_memory_cleanup :: proc(t: ^testing.T) {
  scene: world.World
  world.init(&scene)
  defer world.shutdown(&scene)
  for i in 0 ..< 1000 {
    world.spawn(&scene)
  }
  // expect no memory leaks in the test report
}
