package world

import cont "../containers"
import "../geometry"
import physics "../physics"
import "../resources"
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
  handle: resources.NodeHandle,
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
  handle: resources.NodeHandle,
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
  handle: resources.NodeHandle,
  q: quaternion128,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.rotate_by_quaternion(&node.transform, q)
  }
}

node_rotate_by_angle :: proc(
  world: ^World,
  handle: resources.NodeHandle,
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
  handle: resources.NodeHandle,
  q: quaternion128,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.rotate_quaternion(&node.transform, q)
  }
}

node_rotate_angle :: proc(
  world: ^World,
  handle: resources.NodeHandle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.rotate_angle(&node.transform, angle, axis)
  }
}

node_scale_xyz_by :: proc(
  world: ^World,
  handle: resources.NodeHandle,
  x: f32 = 1,
  y: f32 = 1,
  z: f32 = 1,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_xyz_by(&node.transform, x, y, z)
  }
}

node_scale_by :: proc(world: ^World, handle: resources.NodeHandle, s: f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_by(&node.transform, s)
  }
}

node_scale_xyz :: proc(
  world: ^World,
  handle: resources.NodeHandle,
  x: f32 = 1,
  y: f32 = 1,
  z: f32 = 1,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_xyz(&node.transform, x, y, z)
  }
}

node_scale :: proc(world: ^World, handle: resources.NodeHandle, s: f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale(&node.transform, s)
  }
}

get_node :: proc(world: ^World, handle: resources.NodeHandle) -> (^Node, bool) #optional_ok {
  return cont.get(world.nodes, handle)
}

enable_actor_tick :: proc(
  world: ^World,
  $T: typeid,
  handle: ActorHandle,
) {
  pool := _ensure_actor_pool(world, T)
  actor_enable_tick(pool, handle)
}

disable_actor_tick :: proc(
  world: ^World,
  $T: typeid,
  handle: resources.NodeHandle,
) {
  entry, pool_exists := world.actor_pools[typeid_of(T)]
  if !pool_exists do return
  pool := cast(^ActorPool(T))entry.pool_ptr
  actor_disable_tick(pool, handle)
}

// Sync all nodes with rigid body attachments from physics to world
sync_all_physics_to_world :: proc(world: ^World, physics_world: ^physics.PhysicsWorld) {
  for &entry in world.nodes.entries do if entry.active {
    node := &entry.item
    if attachment, ok := node.attachment.(RigidBodyAttachment); ok {
      if body, ok := physics.get_body(physics_world, attachment.body_handle); ok {
        node.transform.position = body.position
        node.transform.rotation = body.rotation
        node.transform.is_dirty = true
      }
    }
  }
}

// Sync all nodes with rigid body attachments from world to physics
sync_all_world_to_physics :: proc(world: ^World, physics_world: ^physics.PhysicsWorld) {
  for &entry in world.nodes.entries do if entry.active {
    node := &entry.item
    if attachment, ok := node.attachment.(RigidBodyAttachment); ok {
      if body, ok := physics.get_body(physics_world, attachment.body_handle); ok {
        body.position = node.transform.position
        body.rotation = node.transform.rotation
      }
    }
  }
}
