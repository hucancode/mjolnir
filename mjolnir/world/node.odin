package world

import "core:math/linalg"

// translate sets a node's local position.
translate :: proc(self: ^World, handle: NodeHandle, v: [3]f32) {
  node := edit(self, handle)
  if node == nil do return
  node.transform.position = v
}

// rotate sets a node's local rotation:
//   rotate(w, node, q: quaternion128)
//   rotate(w, node, angle: f32, axis: [3]f32 = Y) (radians)
rotate :: proc {
  rotate_quaternion,
  rotate_angle,
}

// rotate_by composes a rotation onto a node's local rotation:
//   rotate_by(w, node, q: quaternion128)
//   rotate_by(w, node, angle: f32, axis: [3]f32 = Y) (radians)
rotate_by :: proc {
  rotate_by_quaternion,
  rotate_by_angle,
}

// scale sets a node's local scale:
//   scale(w, node, s: f32) (uniform)
//   scale(w, node, v: [3]f32)
scale :: proc {
  scale_uniform,
  scale_vec,
}

@(private = "file")
rotate_quaternion :: proc(self: ^World, handle: NodeHandle, q: quaternion128) {
  node := edit(self, handle)
  if node == nil do return
  node.transform.rotation = q
}

@(private = "file")
rotate_angle :: proc(
  self: ^World,
  handle: NodeHandle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  rotate_quaternion(self, handle, linalg.quaternion_angle_axis(angle, axis))
}

@(private = "file")
rotate_by_quaternion :: proc(self: ^World, handle: NodeHandle, q: quaternion128) {
  node := edit(self, handle)
  if node == nil do return
  node.transform.rotation *= q
}

@(private = "file")
rotate_by_angle :: proc(
  self: ^World,
  handle: NodeHandle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  rotate_by_quaternion(self, handle, linalg.quaternion_angle_axis(angle, axis))
}

@(private = "file")
scale_uniform :: proc(self: ^World, handle: NodeHandle, s: f32) {
  scale_vec(self, handle, {s, s, s})
}

@(private = "file")
scale_vec :: proc(self: ^World, handle: NodeHandle, v: [3]f32) {
  node := edit(self, handle)
  if node == nil do return
  node.transform.scale = v
}

// set_local sets a node's whole local transform.
set_local :: proc(
  self: ^World,
  handle: NodeHandle,
  position: [3]f32 = {0, 0, 0},
  rotation: quaternion128 = linalg.QUATERNIONF32_IDENTITY,
  scale: [3]f32 = {1, 1, 1},
) {
  node := edit(self, handle)
  if node == nil do return
  node.transform.position = position
  node.transform.rotation = rotation
  node.transform.scale = scale
}
