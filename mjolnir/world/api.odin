package world

import cont "../containers"
import "../geometry"
import "../physics"
import "core:math"
import "core:math/linalg"

translate_by :: proc {
  geometry.translate_by,
  node_translate_by,
}

translate :: proc {
  geometry.translate,
  node_translate,
}

rotate_by :: proc {
  geometry.rotate_by_quaternion,
  geometry.rotate_by_angle,
  node_rotate_by_quaternion,
  node_rotate_by_angle,
}

rotate :: proc {
  geometry.rotate_quaternion,
  geometry.rotate_angle,
  node_rotate_quaternion,
  node_rotate_angle,
}

scale_xyz_by :: proc {
  geometry.scale_xyz_by,
  node_scale_xyz_by,
}

scale_by :: proc {
  geometry.scale_by,
  node_scale_by,
}

scale_xyz :: proc {
  geometry.scale_xyz,
  node_scale_xyz,
}

scale :: proc {
  geometry.scale,
  node_scale,
}

node_translate_by :: proc(
  world: ^World,
  handle: NodeHandle,
  x: f32 = 0,
  y: f32 = 0,
  z: f32 = 0,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.translate_by(&node.transform, x, y, z)
  }
}

node_translate :: proc(
  world: ^World,
  handle: NodeHandle,
  x: f32 = 0,
  y: f32 = 0,
  z: f32 = 0,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.translate(&node.transform, x, y, z)
  }
}

node_rotate_by :: proc {
  node_rotate_by_quaternion,
  node_rotate_by_angle,
}

node_rotate_by_quaternion :: proc(
  world: ^World,
  handle: NodeHandle,
  q: quaternion128,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.rotate_by_quaternion(&node.transform, q)
  }
}

node_rotate_by_angle :: proc(
  world: ^World,
  handle: NodeHandle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.rotate_by_angle(&node.transform, angle, axis)
  }
}

node_rotate :: proc {
  node_rotate_quaternion,
  node_rotate_angle,
}

node_rotate_quaternion :: proc(
  world: ^World,
  handle: NodeHandle,
  q: quaternion128,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.rotate_quaternion(&node.transform, q)
  }
}

node_rotate_angle :: proc(
  world: ^World,
  handle: NodeHandle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.rotate_angle(&node.transform, angle, axis)
  }
}

node_scale_xyz_by :: proc(
  world: ^World,
  handle: NodeHandle,
  x: f32 = 1,
  y: f32 = 1,
  z: f32 = 1,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_xyz_by(&node.transform, x, y, z)
  }
}

node_scale_by :: proc(world: ^World, handle: NodeHandle, s: f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_by(&node.transform, s)
  }
}

node_scale_xyz :: proc(
  world: ^World,
  handle: NodeHandle,
  x: f32 = 1,
  y: f32 = 1,
  z: f32 = 1,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_xyz(&node.transform, x, y, z)
  }
}

node_scale :: proc(world: ^World, handle: NodeHandle, s: f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale(&node.transform, s)
  }
}

get_node :: proc(
  world: ^World,
  handle: NodeHandle,
) -> (
  ^Node,
  bool,
) #optional_ok {
  return cont.get(world.nodes, handle)
}

// Find first mesh child of a parent node
// Returns (child_handle, child_node, mesh_attachment, ok)
find_first_mesh_child :: proc(
  world: ^World,
  parent_handle: NodeHandle,
) -> (
  child_handle: NodeHandle,
  child_node: ^Node,
  mesh_attachment: ^MeshAttachment,
  ok: bool,
) {
  node := cont.get(world.nodes, parent_handle) or_return
  for child in node.children {
    child_node = cont.get(world.nodes, child) or_continue
    mesh_attachment, has_mesh := &child_node.attachment.(MeshAttachment)
    if has_mesh do return child, child_node, mesh_attachment, true
  }
  return {}, nil, nil, false
}

// Add tags to a node by handle
// Returns false if node not found
tag_node :: proc(
  world: ^World,
  handle: NodeHandle,
  tags: NodeTagSet,
) -> bool {
  node := cont.get(world.nodes, handle) or_return
  node.tags += tags
  return true
}

// Remove tags from a node
// Returns false if node not found
untag_node :: proc(
  world: ^World,
  handle: NodeHandle,
  tags: NodeTagSet,
) -> bool {
  node := cont.get(world.nodes, handle) or_return
  node.tags -= tags
  return true
}

// Sync all nodes with rigid body attachments from physics to world
sync_all_physics_to_world :: proc(
  world: ^World,
  physics_world: ^physics.World,
) {
  for &entry in world.nodes.entries do if entry.active {
    node := &entry.item
    if attachment, ok := node.attachment.(RigidBodyAttachment); ok {
      if body, ok := physics.get_dynamic_body(physics_world, attachment.body_handle); ok {
        node.transform.position = body.position
        node.transform.rotation = body.rotation
        node.transform.is_dirty = true
      }
    }
  }
}
