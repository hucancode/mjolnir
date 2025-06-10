package tests

import mjolnir "../mjolnir"
import resource "../mjolnir/resource"
import geometry "../mjolnir/geometry"
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
  parent_handle, _ := spawn_at(&scene, {1, 2, 3})
  _, child := spawn_child(&scene, parent_handle)
  geometry.translate(&child.transform, 4, 5, 6)
  scene_traverse(&scene)
  actual := child.transform.world_matrix
  expected := linalg.Matrix4f32{
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
  scene: Scene
  scene_init(&scene)
  _, child := spawn(&scene)
  geometry.rotate_angle(&child.transform, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  geometry.translate(&child.transform, 1, 0, 0)
  scene_traverse(&scene)
  actual := child.transform.world_matrix
  expected := linalg.Matrix4f32{
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
  scene: Scene
  scene_init(&scene)
  parent_handle, _ := spawn_at(&scene, {1, 2, 3})
  _, child := spawn_child(&scene, parent_handle)
  geometry.translate(&child.transform, 1, 1, 1)
  geometry.scale_xyz(&child.transform, 2, 3, 4)
  scene_traverse(&scene)
  actual := child.transform.world_matrix
  expected := linalg.Matrix4f32{
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
  scene: Scene
  scene_init(&scene)
  _, node := spawn(&scene)
  geometry.scale(&node.transform, 2)
  geometry.rotate(&node.transform, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
  geometry.translate(&node.transform, 3, 4, 5)
  scene_traverse(&scene)
  actual := node.transform.world_matrix
  // Expected matrix after applying scale, rotation, and translation
  // Scale by 2, then rotate 90 degree around Y, then translate by (3,4,5)
  expected := linalg.Matrix4f32{
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
  scene: Scene
  scene_init(&scene)
  // Create a 4-node chain
  node1_handle, node1 := spawn(&scene)
  node2_handle, node2 := spawn_child(&scene, node1_handle)
  node3_handle, node3 := spawn_child(&scene, node2_handle)
  geometry.translate(&node1.transform, x = 1)
  geometry.rotate_angle(&node2.transform, math.PI / 2, linalg.VECTOR3F32_Y_AXIS)
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
  expected := linalg.Matrix4f32{
    0.0, 0.0, 2.0, 1.0,
    0.0, 2.0, 0.0, 0.0,
    -2.0, 0.0, 0.0, 0.0,
    0.0, 0.0, 0.0, 1.0,
  }
  matrix4_almost_equal(t, actual, expected)
}
