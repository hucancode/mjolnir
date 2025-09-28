package tests

import "../mjolnir"
import "../mjolnir/geometry"
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
  defer world.destroy(&w, nil)
  parent_handle, _ := world.spawn_at(&w, {1, 2, 3})
  _, child := world.spawn_child(&w, parent_handle)
  world.translate(child, 4, 5, 6)
  // Trigger transform update by calling frame processing
  frame_ctx := world.FrameContext{
    frame_index = 0,
    delta_time = 0.016,
    camera = nil,
  }
  world.begin_frame(&w, nil, &frame_ctx)
  actual := child.transform.world_matrix
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
  defer world.destroy(&w, nil)
  _, child := world.spawn(&w)
  world.rotate(child, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  world.translate(child, 1, 0, 0)
  frame_ctx := world.FrameContext{
    frame_index = 0,
    delta_time = 0.016,
    camera = nil,
  }
  world.begin_frame(&w, nil, &frame_ctx)
  actual := child.transform.world_matrix
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
  defer world.destroy(&w, nil)
  parent_handle, _ := world.spawn_at(&w, {1, 2, 3})
  _, child := world.spawn_child(&w, parent_handle)
  world.translate(child, 1, 1, 1)
  world.scale_xyz(child, 2, 3, 4)
  frame_ctx := world.FrameContext{
    frame_index = 0,
    delta_time = 0.016,
    camera = nil,
  }
  world.begin_frame(&w, nil, &frame_ctx)
  actual := child.transform.world_matrix
  expected := matrix[4, 4]f32{
    2.0, 0.0, 0.0, 2.0,
    0.0, 3.0, 0.0, 3.0,
    0.0, 0.0, 4.0, 4.0,
    0.0, 0.0, 0.0, 1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_combined_transform :: proc(t: ^testing.T) {
  using mjolnir
  w: world.World
  world.init(&w)
  defer world.destroy(&w, nil)
  _, node := world.spawn(&w)
  world.scale(node, 2)
  world.rotate(node, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  world.translate(node, 3, 4, 5)
  frame_ctx := world.FrameContext{
    frame_index = 0,
    delta_time = 0.016,
    camera = nil,
  }
  world.begin_frame(&w, nil, &frame_ctx)
  actual := node.transform.world_matrix
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
  defer world.destroy(&w, nil)
  // Create a 4-node chain
  node1_handle, node1 := world.spawn(&w)
  node2_handle, node2 := world.spawn_child(&w, node1_handle)
  node3_handle, node3 := world.spawn_child(&w, node2_handle)
  world.translate(node1, x = 1)
  world.rotate(node2, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  world.scale(node3, 2)
  frame_ctx := world.FrameContext{
    frame_index = 0,
    delta_time = 0.016,
    camera = nil,
  }
  world.begin_frame(&w, nil, &frame_ctx)
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
  if max_depth <= 0 || max_node <= 0 do return
  QueueEntry :: struct {
    handle: resources.Handle,
    depth:  int,
  }
  queue: [dynamic]QueueEntry
  defer delete(queue)
  entry := QueueEntry{scene.root, 0}
  append(&queue, entry)
  n := 0
  for len(queue) > 0 && len(scene.nodes.entries) < max_node {
    current := pop_front(&queue)
    if current.depth < max_depth {
      child_handle, _ := spawn_child(scene, current.handle)
      translate(scene, child_handle, f32(n % 10) * 0.1, 0, 0)
      rotate(scene, child_handle, f32(n) * 0.01, linalg.VECTOR3F32_Y_AXIS)
      append(&queue, QueueEntry{child_handle, current.depth + 1})
    } else {
      child_handle, _ := spawn(scene)
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
  destroy(scene, nil)
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
  defer destroy(&scene, nil)
  for i in 0 ..< 1000 {
    spawn(&scene)
  }
}

@(test)
test_scene_with_multiple_attachments :: proc(t: ^testing.T) {
  using world
  scene: World
  init(&scene)
  defer destroy(&scene, nil)
  spawn(
    &scene,
    LightAttachment {
      // In reality we would need valid light
    },
  )
  spawn(
    &scene,
    MeshAttachment {
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
