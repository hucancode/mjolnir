package geometry

import "core:math/linalg"

// Face is a bolting face: a point, the outward normal and a forward direction along the face.
Face :: struct {
  position, normal, forward: [3]f32,
}

// seat returns the placement (no scale) that bolts `child`'s face onto `parent`'s, in the
// parent's frame: the points meet, the normals oppose and the forwards align.
seat :: proc(parent, child: Face) -> Transform {
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
  rotation := linalg.normalize(linalg.quaternion_from_matrix3_f32(m))
  return {parent.position - linalg.mul(rotation, child.position), rotation, {1, 1, 1}}
}
