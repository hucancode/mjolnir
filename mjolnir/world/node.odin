package world

import cont "../containers"
import "../geometry"
import "core:math/linalg"

translate_by :: proc {
  node_translate_by_xyz,
  node_translate_by_vec,
}

translate :: proc {
  node_translate_xyz,
  node_translate_vec,
}

rotate_by :: proc {
  node_rotate_by_quaternion,
  node_rotate_by_angle,
}

rotate :: proc {
  node_rotate_quaternion,
  node_rotate_angle,
}

scale_xyz_by :: proc {
  node_scale_xyz_by_args,
  node_scale_xyz_by_vec,
}

scale_by :: proc {
  node_scale_by,
}

scale_xyz :: proc {
  node_scale_xyz_args,
  node_scale_xyz_vec,
}

scale :: proc {
  node_scale_uniform,
  node_scale_xyz_vec,
}

node_translate_by_xyz :: proc(
  world: ^World,
  handle: NodeHandle,
  x: f32 = 0,
  y: f32 = 0,
  z: f32 = 0,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.translate_by_xyz(&node.transform, x, y, z)
  }
}

node_translate_by_vec :: proc(
  world: ^World,
  handle: NodeHandle,
  v: [3]f32,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.translate_by_vec(&node.transform, v)
  }
}

node_translate_xyz :: proc(
  world: ^World,
  handle: NodeHandle,
  x: f32 = 0,
  y: f32 = 0,
  z: f32 = 0,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.translate_xyz(&node.transform, x, y, z)
  }
}

node_translate_vec :: proc(world: ^World, handle: NodeHandle, v: [3]f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.translate_vec(&node.transform, v)
  }
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

node_scale_xyz_by_args :: proc(
  world: ^World,
  handle: NodeHandle,
  x: f32 = 1,
  y: f32 = 1,
  z: f32 = 1,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_xyz_by_args(&node.transform, x, y, z)
  }
}

node_scale_xyz_by_vec :: proc(world: ^World, handle: NodeHandle, v: [3]f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_xyz_by_vec(&node.transform, v)
  }
}

node_scale_by :: proc(world: ^World, handle: NodeHandle, s: f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_by(&node.transform, s)
  }
}

node_scale_xyz_args :: proc(
  world: ^World,
  handle: NodeHandle,
  x: f32 = 1,
  y: f32 = 1,
  z: f32 = 1,
) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_xyz_args(&node.transform, x, y, z)
  }
}

node_scale_xyz_vec :: proc(world: ^World, handle: NodeHandle, v: [3]f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_xyz_vec(&node.transform, v)
  }
}

node_scale_uniform :: proc(world: ^World, handle: NodeHandle, s: f32) {
  if node, ok := cont.get(world.nodes, handle); ok {
    geometry.scale_uniform(&node.transform, s)
  }
}
