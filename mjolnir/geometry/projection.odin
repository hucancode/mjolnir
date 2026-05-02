package geometry

import "core:math"

// Vulkan-friendly RH perspective: clip-z in [0, 1], front along -z in view space.
// matches camera/look_at convention used elsewhere in the engine (Odin linalg
// look_at default flip_z_axis=true).
make_perspective_matrix :: proc "contextless" (
  fovy, aspect, near, far: f32,
) -> matrix[4, 4]f32 {
  tan_half := math.tan(0.5 * fovy)
  return matrix[4, 4]f32{
    1 / (aspect * tan_half), 0, 0, 0,
    0, 1 / tan_half, 0, 0,
    0, 0, far / (near - far), near * far / (near - far),
    0, 0, -1, 0,
  }
}

// Vulkan-friendly orthographic: clip-z in [0, 1], front along -z in view space.
make_ortho_matrix :: proc "contextless" (
  left, right, bottom, top, near, far: f32,
) -> matrix[4, 4]f32 {
  rl := right - left
  tb := top - bottom
  nf := near - far
  return matrix[4, 4]f32{
    2 / rl, 0, 0, -(right + left) / rl,
    0, 2 / tb, 0, -(top + bottom) / tb,
    0, 0, 1 / nf, near / nf,
    0, 0, 0, 1,
  }
}

// Vulkan-friendly LH perspective: clip-z in [0, 1], front along +z in view space.
// Used by point-shadow geom shader which builds an LH per-face view (forward
// vector kept as the +z axis instead of negated).
make_perspective_matrix_lh :: proc "contextless" (
  fovy, aspect, near, far: f32,
) -> matrix[4, 4]f32 {
  tan_half := math.tan(0.5 * fovy)
  return matrix[4, 4]f32{
    1 / (aspect * tan_half), 0, 0, 0,
    0, 1 / tan_half, 0, 0,
    0, 0, far / (far - near), -near * far / (far - near),
    0, 0, 1, 0,
  }
}
