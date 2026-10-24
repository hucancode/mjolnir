#+build !js
#+private
package geometry

import "core:math/linalg"
import "core:testing"

@(test)
test_seat_bolts_faces_together :: proc(t: ^testing.T) {
  near :: proc(a, b: [3]f32) -> bool {
    return linalg.length(a - b) < 1e-4
  }
  parent := Face{{1, 0, 0}, {1, 0, 0}, {0, 0, 1}}
  child := Face{{0, 0.5, 0}, {0, 1, 0}, {1, 0, 0}}
  position, rotation := seat(parent, child)
  testing.expect(t, near(position + linalg.quaternion128_mul_vector3(rotation, child.position), parent.position))
  testing.expect(t, near(linalg.quaternion128_mul_vector3(rotation, child.normal), -parent.normal))
  testing.expect(t, near(linalg.quaternion128_mul_vector3(rotation, child.forward), parent.forward))
}
