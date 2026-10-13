package world

import cont "../containers"
import "core:math/linalg"

// Local TRS plus cached matrices. Setters mark `is_dirty`; `update`
// recomputes `local_matrix` and `world_matrix` for dirty subtrees.
Transform :: struct {
  position:     [3]f32,
  rotation:     quaternion128,
  scale:        [3]f32,
  is_dirty:     bool,
  local_matrix: matrix[4, 4]f32,
  world_matrix: matrix[4, 4]f32,
}

@(private)
TRANSFORM_IDENTITY :: Transform {
  rotation     = linalg.QUATERNIONF32_IDENTITY,
  scale        = {1, 1, 1},
  local_matrix = linalg.MATRIX4F32_IDENTITY,
  world_matrix = linalg.MATRIX4F32_IDENTITY,
}

// translate sets a node's local position, from x/y/z or a vector.
translate :: proc {
  translate_xyz,
  translate_vec,
}

// rotate sets a node's local rotation, from a quaternion or angle (and axis, default Y).
rotate :: proc {
  rotate_quaternion,
  rotate_angle,
}

// translate_by moves a node by `v` in its parent's space, on top of its local position
// (translate sets it, as rotate sets and rotate_by composes).
translate_by :: proc(world: ^World, handle: NodeHandle, v: [3]f32) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  node.transform.position += v
  node.transform.is_dirty = true
}

// rotate_by composes a rotation onto a node's local rotation, from a quaternion or angle (and axis, default Y).
rotate_by :: proc {
  rotate_by_quaternion,
  rotate_by_angle,
}

// scale sets a node's local scale, uniform or per axis.
scale :: proc {
  scale_uniform,
  scale_vec,
}

@(private = "file")
translate_xyz :: proc(world: ^World, handle: NodeHandle, x: f32 = 0, y: f32 = 0, z: f32 = 0) {
  translate_vec(world, handle, {x, y, z})
}

@(private = "file")
translate_vec :: proc(world: ^World, handle: NodeHandle, v: [3]f32) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  node.transform.position = v
  node.transform.is_dirty = true
}

@(private = "file")
rotate_quaternion :: proc(world: ^World, handle: NodeHandle, q: quaternion128) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  node.transform.rotation = q
  node.transform.is_dirty = true
}

@(private = "file")
rotate_angle :: proc(
  world: ^World,
  handle: NodeHandle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  rotate_quaternion(world, handle, linalg.quaternion_angle_axis(angle, axis))
}

@(private = "file")
rotate_by_quaternion :: proc(world: ^World, handle: NodeHandle, q: quaternion128) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  node.transform.rotation *= q
  node.transform.is_dirty = true
}

@(private = "file")
rotate_by_angle :: proc(
  world: ^World,
  handle: NodeHandle,
  angle: f32,
  axis: [3]f32 = linalg.VECTOR3F32_Y_AXIS,
) {
  rotate_by_quaternion(world, handle, linalg.quaternion_angle_axis(angle, axis))
}

@(private = "file")
scale_uniform :: proc(world: ^World, handle: NodeHandle, s: f32) {
  scale_vec(world, handle, {s, s, s})
}

@(private = "file")
scale_vec :: proc(world: ^World, handle: NodeHandle, v: [3]f32) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  node.transform.scale = v
  node.transform.is_dirty = true
}

// scale_xyz sets a node's local scale per axis (unset axes are 1).
scale_xyz :: proc(world: ^World, handle: NodeHandle, x: f32 = 1, y: f32 = 1, z: f32 = 1) {
  scale_vec(world, handle, {x, y, z})
}

// set_local sets a node's whole local transform.
set_local :: proc(
  world: ^World,
  handle: NodeHandle,
  position: [3]f32 = {0, 0, 0},
  rotation: quaternion128 = linalg.QUATERNIONF32_IDENTITY,
  scale: [3]f32 = {1, 1, 1},
) {
  node := cont.get(world.nodes, handle)
  if node == nil do return
  node.transform.position = position
  node.transform.rotation = rotation
  node.transform.scale = scale
  node.transform.is_dirty = true
}
