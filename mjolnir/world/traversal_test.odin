#+build !js
#+private
package world

import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

@(private = "file")
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
test_set_world_pose_under_moved_root :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)
  translate(&w, w.root, 10, 0, 0)
  child, ok := node_create(&w)
  testing.expect(t, ok)
  update(&w)
  set_world_pose(&w, child, {1, 2, 3}, linalg.QUATERNIONF32_IDENTITY)
  update(&w)
  m := world_matrix(&w, child)
  testing.expectf(t, linalg.length(m[3].xyz - [3]f32{1, 2, 3}) < 1e-4, "child at %v", m[3].xyz)
}

@(test)
test_set_visible_reports_subtree :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)
  parent, _ := node_create(&w)
  child, _ := node_create(&w, parent = parent)
  update(&w)
  update(&w)
  testing.expect_value(t, len(changes(&w)), 0)
  set_visible(&w, parent, false)
  update(&w)
  feed := changes(&w)
  testing.expect_value(t, len(feed), 2)
  for c in feed do testing.expect(t, !c.visible)
  set_visible(&w, child, false)
  update(&w)
  testing.expect_value(t, len(changes(&w)), 0)
  set_visible(&w, parent, true)
  update(&w)
  feed = changes(&w)
  testing.expect_value(t, len(feed), 1)
  testing.expect(t, feed[0].index == parent.index && feed[0].visible)
}

@(test)
test_node_translate :: proc(t: ^testing.T) {
  w: World
  init(&w)
  defer shutdown(&w)
  parent_handle, parent_ok := node_create(&w, {1, 2, 3})
  testing.expectf(t, parent_ok, "failed to spawn parent node")
  child, ok := node_create(&w, parent = parent_handle)
  child_ptr := node(&w, child)
  testing.expectf(t, ok, "failed to spawn child node")
  translate(&w, child, 4, 5, 6)
  update(&w)
  actual := world_matrix(&w, child)
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
  w: World
  init(&w)
  defer shutdown(&w)
  child, ok := node_create(&w)
  child_ptr := node(&w, child)
  testing.expectf(t, ok, "failed to spawn node")
  rotate(&w, child, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  translate(&w, child, 1, 0, 0)
  update(&w)
  actual := world_matrix(&w, child)
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
  w: World
  init(&w)
  defer shutdown(&w)
  parent_handle, parent_ok := node_create(&w, {1, 2, 3})
  testing.expectf(t, parent_ok, "failed to spawn parent node")
  child, child_ok := node_create(&w, parent = parent_handle)
  child_ptr := node(&w, child)
  testing.expectf(t, child_ok, "failed to spawn child node")
  scale(&w, child, 5, 6, 7)
  update(&w)
  actual := world_matrix(&w, child)
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
  w: World
  init(&w)
  defer shutdown(&w)
  n, node_ok := node_create(&w)
  node_ptr := node(&w, n)
  testing.expectf(t, node_ok, "failed to spawn node")
  scale(&w, n, 2)
  rotate(&w, n, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  translate(&w, n, 3, 4, 5)
  update(&w)
  actual := world_matrix(&w, n)
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
  w: World
  init(&w)
  defer shutdown(&w)
  // Create a 4-node chain
  node1_handle, node1_ok := node_create(&w)
  testing.expectf(t, node1_ok, "failed to spawn node1")
  node2_handle, node2_ok := node_create(&w, parent = node1_handle)
  testing.expectf(t, node2_ok, "failed to spawn node2")
  node3_handle, node3_ok := node_create(&w, parent = node2_handle)
  node3 := node(&w, node3_handle)
  testing.expectf(t, node3_ok, "failed to spawn node3")
  translate(&w, node1_handle, x = 1)
  rotate(&w, node2_handle, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  scale(&w, node3_handle, 2)
  update(&w)
  // The transforms should cascade:
  // node1: translate(1,0,0)
  // node2: translate(1,0,0) * rotate_y(90°)
  // node3: translate(1,0,0) * rotate_y(90°) * scale(2)
  actual := world_matrix(&w, node3_handle)
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

@(private = "file")
create_scene :: proc(self: ^World, max_node: int, max_depth: int) {
  target_nodes := max_node
  if self.slots.capacity > 0 {
    target_nodes = min(target_nodes, int(self.slots.capacity))
  }
  if max_depth <= 0 || target_nodes <= 0 do return
  QueueEntry :: struct {
    handle: NodeHandle,
    depth:  int,
  }
  queue: [dynamic]QueueEntry
  defer delete(queue)
  entry := QueueEntry{self.root, 0}
  append(&queue, entry)
  n := 0
  count := node_count(self)
  for len(queue) > 0 && count < target_nodes {
    current := pop_front(&queue)
    if current.depth < max_depth {
      child_handle := node_create(self, parent = current.handle) or_continue
      translate(self, child_handle, f32(n % 10) * 0.1, 0, 0)
      rotate(
        self,
        child_handle,
        f32(n) * 0.01,
        linalg.VECTOR3F32_Y_AXIS,
      )
      append(&queue, QueueEntry{child_handle, current.depth + 1})
    } else {
      child_handle := node_create(self) or_continue
      translate(self, child_handle, f32(n % 10) * 0.1, 0, 0)
      rotate(
        self,
        child_handle,
        f32(n) * 0.01,
        linalg.VECTOR3F32_Y_AXIS,
      )
      append(&queue, QueueEntry{child_handle, 1})
    }
    n += 1
    count += 1
  }
  log.infof(
    "Generated a scene with %d nodes and max depth %d",
    node_count(self),
    max_depth,
  )
}

traverse_scene_benchmark :: proc(
  options: ^time.Benchmark_Options,
  allocator := context.allocator,
) -> time.Benchmark_Error {
  scene := cast(^World)(raw_data(options.input))
  // simulate an use case that traverse the scene and count the number of lights and meshes
  Context :: struct {
    light_count: u32,
    mesh_count:  u32,
  }
  count := node_count(scene)
  for _ in 0 ..< options.rounds {
    ctx: Context
    traverse(scene)
    options.processed += size_of(Node) * count
  }
  return nil
}

@(private = "file")
teardown_scene :: proc(
  options: ^time.Benchmark_Options,
  allocator := context.allocator,
) -> time.Benchmark_Error {
  scene := cast(^World)(raw_data(options.input))
  shutdown(scene)
  free(scene, allocator)
  return nil
}

@(test)
benchmark_deep_scene_traversal :: proc(t: ^testing.T) {
  N :: 1000_000
  ROUND :: 5
  options := &time.Benchmark_Options {
    rounds = ROUND,
    bytes = size_of(Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(World)
      init(scene)
      create_scene(scene, N, N)
      build_tree(scene)
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
    bytes = size_of(Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(World)
      init(scene)
      create_scene(scene, N, 1)
      build_tree(scene)
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
    bytes = size_of(Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(World)
      init(scene)
      create_scene(scene, N, MAX_DEPTH)
      build_tree(scene)
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
  scene: World
  init(&scene)
  defer shutdown(&scene)
  for i in 0 ..< 1000 {
    node_create(&scene)
  }
  // expect no memory leaks in the test report
}

// Live nodes, root included.
node_count :: proc(self: ^World) -> int {
  return int(self.slots.count)
}

@(test)
test_set_parent_moves_subtree :: proc(t: ^testing.T) {
  w: World
  init(&w, 64)
  defer shutdown(&w)
  a := spawn(&w, {10, 0, 0})
  b := spawn(&w, {0, 5, 0})
  child := spawn(&w, {1, 0, 0}, parent = a)
  update(&w)
  testing.expect(t, set_parent(&w, child, b), "reparent")
  update(&w)
  testing.expect_value(t, world_matrix(&w, child)[3].xyz, [3]f32{1, 5, 0})
  testing.expect(t, len(children(&w, a)) == 0 && len(children(&w, b)) == 1, "child lists follow")
  testing.expect(t, set_parent(&w, child, a, keep_world = true), "reparent keeping the world pose")
  update(&w)
  testing.expect_value(t, world_matrix(&w, child)[3].xyz, [3]f32{1, 5, 0})
  testing.expect(t, !set_parent(&w, a, child), "a node cannot hang under its own subtree")
  testing.expect(t, !set_parent(&w, w.root, a), "the root has no parent")
}

@(test)
test_setup_keeps_nodes_through_teardown :: proc(t: ^testing.T) {
  w: World
  init(&w, 64)
  defer shutdown(&w)
  player := spawn(&w, {1, 0, 0})
  setup(&w)
  level := spawn(&w, {2, 0, 0})
  held := spawn(&w, parent = player)
  update(&w)
  teardown(&w)
  update(&w)
  _, kept := node(&w, player)
  _, dropped := node(&w, level)
  _, child_dropped := node(&w, held)
  testing.expect(t, kept && !dropped && !child_dropped, "teardown keeps what setup marked, drops the rest")
  testing.expect(t, len(children(&w, player)) == 0, "a kept node's later children go")
}

@(test)
test_update_walks_only_touched_subtrees :: proc(t: ^testing.T) {
  w: World
  init(&w, 256)
  defer shutdown(&w)
  nodes: [100]NodeHandle
  for &n, i in nodes do n = spawn(&w, {f32(i), 0, 0})
  child := spawn(&w, {0, 1, 0}, parent = nodes[42])
  update(&w)
  translate(&w, nodes[42], 0, 0, 5)
  update(&w)
  feed := changes(&w)
  testing.expect_value(t, len(feed), 2)
  testing.expect_value(t, world_matrix(&w, child)[3].xyz, [3]f32{0, 1, 5})
  update(&w)
  testing.expect_value(t, len(changes(&w)), 0)
}
