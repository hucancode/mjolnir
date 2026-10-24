package mech

import "../containers"
import "core:math"
import "core:math/linalg"

Handle :: containers.Handle

// Axis is the one degree of freedom of a bone: a turn about a local axis or a slide along it.
Axis :: enum u8 {
  X,
  Y,
  Z,
  TX,
  TY,
  TZ,
}

// Bone is one joint axis. Its frame is parent ∘ offset ∘ rest ∘ the axis moved by
// sign * channels[channel], clamped to [lower, upper] when upper > lower (radians for a turn,
// units for a slide). A bone with sign 0 never moves. A ball joint is three bones on X, Y and Z.
Bone :: struct {
  parent:       int,
  offset:       [3]f32,
  rest:         quaternion128,
  axis:         Axis,
  channel:      int,
  sign:         f32,
  lower, upper: f32,
  user:         Handle,
}

// Pose is a bone's world placement, handed back with the bone's user handle; it fits
// world.set_world_poses as physics.BodyPose does.
Pose :: struct {
  user:     Handle,
  position: [3]f32,
  rotation: quaternion128,
}

// Mech is a bone tree placed at position and rotation. Bones come parents first; the root
// bones have parent -1. The application writes bones, position and rotation; solve writes poses.
Mech :: struct {
  bones:    [dynamic]Bone,
  position: [3]f32,
  rotation: quaternion128,
  poses:    [dynamic]Pose,
}

// Face is a bolting face: a point, the outward normal and a forward direction along the face.
Face :: struct {
  position, normal, forward: [3]f32,
}

// make_bone returns a bone; the defaults make a fixed bone with no rest turn.
make_bone :: proc(
  parent: int,
  offset: [3]f32 = {},
  rest := linalg.QUATERNIONF32_IDENTITY,
  axis := Axis.X,
  channel := 0,
  sign: f32 = 0,
  lower: f32 = 0,
  upper: f32 = 0,
  user: Handle = {},
) -> Bone {
  return {parent, offset, rest, axis, channel, sign, lower, upper, user}
}

init :: proc(self: ^Mech, position: [3]f32 = {}, rotation := linalg.QUATERNIONF32_IDENTITY) {
  self^ = {position = position, rotation = rotation}
}

destroy :: proc(self: ^Mech) {
  delete(self.bones)
  delete(self.poses)
  self^ = {}
}

// value returns the clamped amount bone `i` is turned or slid by under `channels`.
value :: proc(self: ^Mech, i: int, channels: []f32) -> f32 {
  b := self.bones[i]
  if b.sign == 0 || b.channel < 0 || b.channel >= len(channels) do return 0
  v := b.sign * channels[b.channel]
  return clamp(v, b.lower, b.upper) if b.upper > b.lower else v
}

// solve poses every bone in the world under `channels` and returns the poses, one per bone.
solve :: proc(self: ^Mech, channels: []f32) -> []Pose {
  resize(&self.poses, len(self.bones))
  for b, i in self.bones {
    position, rotation := self.position, self.rotation
    if b.parent >= 0 do position, rotation = self.poses[b.parent].position, self.poses[b.parent].rotation
    position += linalg.quaternion128_mul_vector3(rotation, b.offset)
    rotation *= b.rest
    v := value(self, i, channels)
    switch b.axis {
    case .X, .Y, .Z:
      axis: [3]f32
      axis[int(b.axis)] = 1
      rotation *= linalg.quaternion_angle_axis_f32(v, axis)
    case .TX, .TY, .TZ:
      slide: [3]f32
      slide[int(b.axis) - int(Axis.TX)] = v
      position += linalg.quaternion128_mul_vector3(rotation, slide)
    }
    self.poses[i] = {b.user, position, linalg.normalize(rotation)}
  }
  return self.poses[:]
}

// seat returns the placement that bolts `child`'s face onto `parent`'s, in the parent's frame:
// the points meet, the normals oppose and the forwards align.
seat :: proc(parent, child: Face) -> (position: [3]f32, rotation: quaternion128) {
  frame :: proc(normal, forward: [3]f32) -> matrix[3, 3]f32 {
    n, f := linalg.normalize(normal), linalg.normalize(forward)
    b := linalg.cross(n, f)
    return matrix[3, 3]f32{
      f.x, b.x, n.x,
      f.y, b.y, n.y,
      f.z, b.z, n.z,
    }
  }
  m := frame(-parent.normal, parent.forward) * linalg.transpose(frame(child.normal, child.forward))
  rotation = linalg.normalize(linalg.quaternion_from_matrix3_f32(m))
  position = parent.position - linalg.quaternion128_mul_vector3(rotation, child.position)
  return
}

// two_link solves a planar two-link chain of lengths l1 and l2 to reach `target`. a is the
// first link's angle from +x toward +y, b the second's turn off the first, folding toward -y
// (b <= 0). A target out of reach straightens or folds the chain toward it and reached is false.
two_link :: proc(l1, l2: f32, target: [2]f32) -> (a, b: f32, reached: bool) {
  r := linalg.length(target)
  reached = r <= l1 + l2 && r >= abs(l1 - l2)
  b = -math.acos(clamp((r * r - l1 * l1 - l2 * l2) / (2 * l1 * l2), -1, 1))
  a = math.atan2(target.y, target.x) - math.atan2(l2 * math.sin(b), l1 + l2 * math.cos(b))
  return
}
