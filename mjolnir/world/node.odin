package world

import "core:math/linalg"

// Transform is a node's local position, rotation and scale; update derives its world
// matrix (world_matrix reads it).
Transform :: struct {
  position: [3]f32,
  rotation: quaternion128,
  scale:    [3]f32,
}

@(private)
TRANSFORM_IDENTITY :: Transform {
  rotation = linalg.QUATERNIONF32_IDENTITY,
  scale    = {1, 1, 1},
}

// translate sets a node's local position:
//   translate(w, node, x = 0, y = 0, z = 0)
//   translate(w, node, v: [3]f32)
translate :: proc {
  translate_xyz,
  translate_vec,
}

// rotate sets a node's local rotation:
//   rotate(w, node, q: quaternion128)
//   rotate(w, node, angle: f32, axis: [3]f32 = Y) (radians)
rotate :: proc {
  rotate_quaternion,
  rotate_angle,
}

// translate_by moves a node by `v` in its parent's space, on top of its local position
// (translate sets it, as rotate sets and rotate_by composes).
translate_by :: proc(self: ^World, handle: NodeHandle, v: [3]f32) {
  node := lookup(self, handle)
  if node == nil do return
  node.transform.position += v
  self.cache[handle.index].is_dirty = true
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
//   scale(w, node, x, y, z: f32)
//   scale(w, node, v: [3]f32)
scale :: proc {
  scale_uniform,
  scale_xyz,
  scale_vec,
}

@(private = "file")
translate_xyz :: proc(self: ^World, handle: NodeHandle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  translate_vec(self, handle, {x, y, z})
}

@(private = "file")
translate_vec :: proc(self: ^World, handle: NodeHandle, v: [3]f32) {
  node := lookup(self, handle)
  if node == nil do return
  node.transform.position = v
  self.cache[handle.index].is_dirty = true
}

@(private = "file")
rotate_quaternion :: proc(self: ^World, handle: NodeHandle, q: quaternion128) {
  node := lookup(self, handle)
  if node == nil do return
  node.transform.rotation = q
  self.cache[handle.index].is_dirty = true
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
  node := lookup(self, handle)
  if node == nil do return
  node.transform.rotation *= q
  self.cache[handle.index].is_dirty = true
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
  node := lookup(self, handle)
  if node == nil do return
  node.transform.scale = v
  self.cache[handle.index].is_dirty = true
}

@(private = "file")
scale_xyz :: proc(self: ^World, handle: NodeHandle, x, y, z: f32) {
  scale_vec(self, handle, {x, y, z})
}

// set_local sets a node's whole local transform.
set_local :: proc(
  self: ^World,
  handle: NodeHandle,
  position: [3]f32 = {0, 0, 0},
  rotation: quaternion128 = linalg.QUATERNIONF32_IDENTITY,
  scale: [3]f32 = {1, 1, 1},
) {
  node := lookup(self, handle)
  if node == nil do return
  node.transform.position = position
  node.transform.rotation = rotation
  node.transform.scale = scale
  self.cache[handle.index].is_dirty = true
}
