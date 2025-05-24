package mjolnir

import "core:fmt"
import "core:math"
import linalg "core:math/linalg"
import "resource"

Scene :: struct {
  camera: Camera,
  root:   Handle,
}

init_scene :: proc(s: ^Scene) {
  s.camera = camera_init_orbit(
    math.PI * 0.5, // fov
    16.0 / 9.0, // aspect_ratio
    0.01, // near
    100.0, // far
  )
}

deinit_scene :: proc(s: ^Scene) {
}


rotate_orbit_camera_scene :: proc(
  s: ^Scene,
  delta_yaw: f32,
  delta_pitch: f32,
) {
  camera_orbit_rotate(&s.camera, delta_yaw, delta_pitch)
}

switch_camera_mode_scene :: proc(s: ^Scene) {
  _, in_orbit_mode := s.camera.movement_data.(CameraOrbitMovement)
  if in_orbit_mode {
    camera_switch_to_free(&s.camera)
  } else {
    camera_switch_to_orbit(&s.camera, nil, nil)
  }
}

traverse_scene :: proc(
  scene: ^Scene,
  nodes: ^resource.ResourcePool(Node),
  cb_context: rawptr,
  callback: proc(
    node: ^Node,
    world_matrix: ^linalg.Matrix4f32,
    cb_context: rawptr,
  ) -> bool,
) -> bool {
  node_stack := make([dynamic]Handle, 0)
  defer delete(node_stack)
  transform_stack := make([dynamic]linalg.Matrix4f32, 0)
  defer delete(transform_stack)

  append(&node_stack, scene.root)
  append(&transform_stack, linalg.MATRIX4F32_IDENTITY)

  for len(node_stack) > 0 {
    current_node_handle := pop(&node_stack)
    parent_world_matrix := pop(&transform_stack)

    current_node := resource.get(nodes, current_node_handle)
    if current_node == nil {
      fmt.eprintf(
        "traverse_scene: Node with handle %v not found\n",
        current_node_handle,
      )
      continue
    }

    // TODO: instead of DFS and update transform matrix on render, we should transform on object request
    // Ensure transform is up-to-date (local_matrix from TRS)
    if current_node.transform.is_dirty {
      current_node.transform.local_matrix = linalg.matrix4_from_trs(
        current_node.transform.position,
        current_node.transform.rotation,
        current_node.transform.scale,
      )
      // current_node.transform.is_dirty = false; // World matrix update will clear it if needed
    }
    current_node.transform.world_matrix =
      parent_world_matrix * current_node.transform.local_matrix
    current_node.transform.is_dirty = false

    if !callback(
      current_node,
      &current_node.transform.world_matrix,
      cb_context,
    ) {
      continue
    }

    for child_handle in current_node.children {
      append(&node_stack, child_handle)
      append(&transform_stack, current_node.transform.world_matrix)
    }
  }
  return true
}
