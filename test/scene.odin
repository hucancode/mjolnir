package tests

import "../mjolnir"
import "../mjolnir/resources"
import world "../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
test_node_translate :: proc(t: ^testing.T) {
  using mjolnir
  w: world.World
  world.init(&w)
  defer world.shutdown(&w, nil, nil)
  parent_handle, parent_ok := world.spawn(&w, {1, 2, 3})
  testing.expectf(t, parent_ok, "failed to spawn parent node")
  child, ok := world.spawn_child(&w, parent_handle)
  child_ptr := world.get_node(&w, child)
  testing.expectf(t, ok, "failed to spawn child node")
  world.translate(&w, child, 4, 5, 6)
  world.begin_frame(&w, nil)
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
  using mjolnir
  w: world.World
  world.init(&w)
  defer world.shutdown(&w, nil, nil)
  child, ok := world.spawn(&w)
  child_ptr := world.get_node(&w, child)
  testing.expectf(t, ok, "failed to spawn node")
  world.rotate(&w, child, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  world.translate(&w, child, 1, 0, 0)
  world.begin_frame(&w, nil)
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
  using mjolnir
  w: world.World
  world.init(&w)
  defer world.shutdown(&w, nil, nil)
  parent_handle, parent_ok := world.spawn(&w, {1, 2, 3})
  testing.expectf(t, parent_ok, "failed to spawn parent node")
  child, child_ok := world.spawn_child(&w, parent_handle)
  child_ptr := world.get_node(&w, child)
  testing.expectf(t, child_ok, "failed to spawn child node")
  world.scale_xyz(&w, child, 5, 6, 7)
  world.begin_frame(&w, nil)
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
  using mjolnir
  w: world.World
  world.init(&w)
  defer world.shutdown(&w, nil, nil)
  node, node_ok := world.spawn(&w)
  node_ptr := world.get_node(&w, node)
  testing.expectf(t, node_ok, "failed to spawn node")
  world.scale(&w, node, 2)
  world.rotate(&w, node, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  world.translate(&w, node, 3, 4, 5)
  world.begin_frame(&w, nil)
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
  using mjolnir
  w: world.World
  world.init(&w)
  defer world.shutdown(&w, nil, nil)
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
  world.begin_frame(&w, nil)
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
  using world
  target_nodes := max_node
  if scene.nodes.capacity > 0 {
    target_nodes = min(target_nodes, int(scene.nodes.capacity))
  }
  if max_depth <= 0 || target_nodes <= 0 do return
  QueueEntry :: struct {
    handle: resources.NodeHandle,
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
      child_handle := spawn_child(scene, current.handle) or_continue
      translate(scene, child_handle, f32(n % 10) * 0.1, 0, 0)
      rotate(scene, child_handle, f32(n) * 0.01, linalg.VECTOR3F32_Y_AXIS)
      append(&queue, QueueEntry{child_handle, current.depth + 1})
    } else {
      child_handle := spawn(scene) or_continue
      translate(scene, child_handle, f32(n % 10) * 0.1, 0, 0)
      rotate(scene, child_handle, f32(n) * 0.01, linalg.VECTOR3F32_Y_AXIS)
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
  using world
  scene := cast(^World)(raw_data(options.input))
  // simulate an use case that traverse the scene and count the number of lights and meshes
  Context :: struct {
    light_count: u32,
    mesh_count:  u32,
  }
  callback :: proc(node: ^world.Node, cb_context: rawptr) -> bool {
    using world
    ctx := (^Context)(cb_context)
    #partial switch inner in node.attachment {
    case MeshAttachment:
      ctx.mesh_count += 1
    case LightAttachment:
      ctx.light_count += 1
    }
    return true
  }
  for _ in 0 ..< options.rounds {
    ctx: Context
    traverse(scene, nil, &ctx, callback)
    options.processed += size_of(Node) * len(scene.nodes.entries)
  }
  return nil
}

teardown_scene :: proc(
  options: ^time.Benchmark_Options,
  allocator := context.allocator,
) -> time.Benchmark_Error {
  using world
  scene := cast(^World)(raw_data(options.input))
  shutdown(scene, nil, nil)
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
      using world
      scene := new(World)
      init(scene)
      create_scene(scene, N, N)
      options.input = slice.bytes_from_ptr(scene, size_of(^World))
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
      using world
      scene := new(World)
      init(scene)
      create_scene(scene, N, 1)
      options.input = slice.bytes_from_ptr(scene, size_of(^World))
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
      using world
      scene := new(World)
      init(scene)
      create_scene(scene, N, MAX_DEPTH)
      options.input = slice.bytes_from_ptr(scene, size_of(^World))
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
  using world
  scene: World
  init(&scene)
  defer shutdown(&scene, nil, nil)
  for i in 0 ..< 1000 {
    spawn(&scene)
  }
}

@(test)
test_scene_with_multiple_attachments :: proc(t: ^testing.T) {
  using world
  scene: World
  init(&scene)
  defer shutdown(&scene, nil, nil)
  spawn(
    &scene,
    attachment = LightAttachment {
      // In reality we would need valid light
    },
  )
  spawn(
    &scene,
    attachment = MeshAttachment {
      // In reality we would need valid mesh handle
    },
  )
  Context :: struct {
    light_count: int,
    mesh_count:  int,
  }
  callback :: proc(node: ^world.Node, ctx: rawptr) -> bool {
    using world
    counter := (^Context)(ctx)
    #partial switch attachment in node.attachment {
    case LightAttachment:
      counter.light_count += 1
    case MeshAttachment:
      counter.mesh_count += 1
    }
    return true
  }
  ctx := Context {
    light_count = 0,
    mesh_count  = 0,
  }
  world.traverse(&scene, nil, &ctx, callback)
  testing.expect_value(t, ctx.light_count, 1)
  testing.expect_value(t, ctx.mesh_count, 1)
}
