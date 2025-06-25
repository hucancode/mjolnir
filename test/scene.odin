package tests

import mjolnir "../mjolnir"
import geometry "../mjolnir/geometry"
import resource "../mjolnir/resource"
import "core:fmt"
import "core:log"
import "core:math"
import linalg "core:math/linalg"
import "core:slice"
import "core:testing"
import "core:time"

@(test)
test_node_translate :: proc(t: ^testing.T) {
  using mjolnir
  scene: Scene
  scene_init(&scene)
  defer scene_deinit(&scene)
  parent_handle, _ := spawn_at(&scene, {1, 2, 3})
  _, child := spawn_child(&scene, parent_handle)
  geometry.translate(&child.transform, 4, 5, 6)
  scene_traverse(&scene)
  actual := child.transform.world_matrix
  expected := linalg.Matrix4f32 {
    1.0,
    0.0,
    0.0,
    5.0,
    0.0,
    1.0,
    0.0,
    7.0,
    0.0,
    0.0,
    1.0,
    9.0,
    0.0,
    0.0,
    0.0,
    1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_rotate :: proc(t: ^testing.T) {
  using mjolnir
  scene: Scene
  scene_init(&scene)
  defer scene_deinit(&scene)
  _, child := spawn(&scene)
  geometry.rotate_angle(
    &child.transform,
    math.PI / 2,
    linalg.VECTOR3F32_Y_AXIS,
  )
  geometry.translate(&child.transform, 1, 0, 0)
  scene_traverse(&scene)
  actual := child.transform.world_matrix
  expected := linalg.Matrix4f32 {
    0.0,
    0.0,
    1.0,
    1.0,
    0.0,
    1.0,
    0.0,
    0.0,
    -1.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_scale :: proc(t: ^testing.T) {
  using mjolnir
  scene: Scene
  scene_init(&scene)
  defer scene_deinit(&scene)
  parent_handle, _ := spawn_at(&scene, {1, 2, 3})
  _, child := spawn_child(&scene, parent_handle)
  geometry.translate(&child.transform, 1, 1, 1)
  geometry.scale_xyz(&child.transform, 2, 3, 4)
  scene_traverse(&scene)
  actual := child.transform.world_matrix
  expected := linalg.Matrix4f32 {
    2.0,
    0.0,
    0.0,
    2.0,
    0.0,
    3.0,
    0.0,
    3.0,
    0.0,
    0.0,
    4.0,
    4.0,
    0.0,
    0.0,
    0.0,
    1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_combined_transform :: proc(t: ^testing.T) {
  using mjolnir
  scene: Scene
  scene_init(&scene)
  defer scene_deinit(&scene)
  _, node := spawn(&scene)
  geometry.scale(&node.transform, 2)
  geometry.rotate(&node.transform, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  geometry.translate(&node.transform, 3, 4, 5)
  scene_traverse(&scene)
  actual := node.transform.world_matrix
  // Expected matrix after applying scale, rotation, and translation
  // Scale by 2, then rotate 90 degree around Y, then translate by (3,4,5)
  expected := linalg.Matrix4f32 {
    0.0,
    0.0,
    2.0,
    3.0,
    0.0,
    2.0,
    0.0,
    4.0,
    -2.0,
    0.0,
    0.0,
    5.0,
    0.0,
    0.0,
    0.0,
    1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

@(test)
test_node_chain_transform :: proc(t: ^testing.T) {
  using mjolnir
  scene: Scene
  scene_init(&scene)
  defer scene_deinit(&scene)
  // Create a 4-node chain
  node1_handle, node1 := spawn(&scene)
  node2_handle, node2 := spawn_child(&scene, node1_handle)
  node3_handle, node3 := spawn_child(&scene, node2_handle)
  geometry.translate(&node1.transform, x = 1)
  geometry.rotate_angle(
    &node2.transform,
    math.PI / 2,
    linalg.VECTOR3F32_Y_AXIS,
  )
  geometry.scale(&node3.transform, 2)
  scene_traverse(&scene)
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
  expected := linalg.Matrix4f32 {
    0.0,
    0.0,
    2.0,
    1.0,
    0.0,
    2.0,
    0.0,
    0.0,
    -2.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    0.0,
    1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}

create_scene :: proc(scene: ^mjolnir.Scene, max_node: int, max_depth: int) {
  if max_depth <= 0 || max_node <= 0 do return
  QueueEntry :: struct {
    handle: resource.Handle,
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
      child_handle, child := mjolnir.spawn_child(scene, current.handle)
      geometry.translate(&child.transform, f32(n % 10) * 0.1, 0, 0)
      geometry.rotate_angle(
        &child.transform,
        f32(n) * 0.01,
        linalg.VECTOR3F32_Y_AXIS,
      )
      append(&queue, QueueEntry{child_handle, current.depth + 1})
    } else {
      child_handle, child := mjolnir.spawn(scene)
      geometry.translate(&child.transform, f32(n % 10) * 0.1, 0, 0)
      geometry.rotate_angle(
        &child.transform,
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
  scene := cast(^mjolnir.Scene)(raw_data(options.input))
  // simulate an use case that traverse the scene and count the number of lights and meshes
  Context :: struct {
    light_count: u32,
    mesh_count:  u32,

  }
  callback :: proc(node: ^mjolnir.Node, cb_context: rawptr) -> bool {
    ctx := (^Context)(cb_context)
    #partial switch inner in node.attachment {
    case mjolnir.MeshAttachment:
      ctx.mesh_count += 1
    case mjolnir.DirectionalLightAttachment,
         mjolnir.PointLightAttachment,
         mjolnir.SpotLightAttachment:
      ctx.light_count += 1
    }
    return true
  }
  for _ in 0 ..< options.rounds {
    ctx: Context
    mjolnir.scene_traverse(scene, &ctx, callback)
    options.processed += size_of(mjolnir.Node) * len(scene.nodes.entries)
  }
  return nil
}

teardown_scene :: proc(
  options: ^time.Benchmark_Options,
  allocator := context.allocator,
) -> time.Benchmark_Error {
  scene := cast(^mjolnir.Scene)(raw_data(options.input))
  mjolnir.scene_deinit(scene)
  free(scene, allocator)
  return nil
}

@(test)
benchmark_deep_scene_traversal :: proc(t: ^testing.T) {
  N :: 1000_000
  ROUND :: 5
  options := &time.Benchmark_Options {
    rounds = ROUND,
    bytes = size_of(mjolnir.Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(mjolnir.Scene)
      mjolnir.scene_init(scene)
      create_scene(scene, N, N)
      options.input = slice.bytes_from_ptr(scene, size_of(^mjolnir.Scene))
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
    bytes = size_of(mjolnir.Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(mjolnir.Scene)
      mjolnir.scene_init(scene)
      create_scene(scene, N, 1)
      options.input = slice.bytes_from_ptr(scene, size_of(^mjolnir.Scene))
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
    bytes = size_of(mjolnir.Node) * N * ROUND,
    setup = proc(
      options: ^time.Benchmark_Options,
      allocator := context.allocator,
    ) -> time.Benchmark_Error {
      scene := new(mjolnir.Scene)
      mjolnir.scene_init(scene)
      create_scene(scene, N, MAX_DEPTH)
      options.input = slice.bytes_from_ptr(scene, size_of(^mjolnir.Scene))
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
    scene: mjolnir.Scene
    mjolnir.scene_init(&scene)
    defer mjolnir.scene_deinit(&scene)
    for i in 0..<1000 {
        mjolnir.spawn(&scene)
    }
}

@(test)
test_scene_with_multiple_attachments :: proc(t: ^testing.T) {
    scene: mjolnir.Scene
    mjolnir.scene_init(&scene)
    defer mjolnir.scene_deinit(&scene)
    mjolnir.spawn(&scene, mjolnir.PointLightAttachment{
        // In reality we would need valid light
    })
    mjolnir.spawn(&scene, mjolnir.MeshAttachment{
        // In reality we would need valid mesh handle
    })
    Context :: struct {
        light_count: int,
        mesh_count: int
    }
    callback :: proc(node: ^mjolnir.Node, ctx: rawptr) -> bool {
        counter := (^Context)(ctx)
        #partial switch attachment in node.attachment {
        case mjolnir.PointLightAttachment:
            counter.light_count += 1
        case mjolnir.MeshAttachment:
            counter.mesh_count += 1
        }
        return true
    }
    ctx := Context{
        light_count = 0,
        mesh_count = 0,
    }
    mjolnir.scene_traverse(&scene, &ctx, callback)
    testing.expect_value(t, ctx.light_count, 1)
    testing.expect_value(t, ctx.mesh_count, 1)
}
