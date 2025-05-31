package tests

import "../mjolnir/geometry"
import "core:math"
import linalg "core:math/linalg"
import "core:testing"

@(test)
test_frustum_aabb_inside :: proc(t: ^testing.T) {
  // Create a simple orthographic frustum centered at origin
  // For simplicity, use identity matrix (frustum from -1 to 1 in all axes)
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  // AABB fully inside the frustum
  aabb := geometry.Aabb{
      linalg.Vector3f32{-0.5, -0.5, -0.5},
      linalg.Vector3f32{0.5, 0.5, 0.5},
  }
  inside := geometry.frustum_test_aabb(&frustum, aabb)
  testing.expect(t, inside, "AABB should be inside the frustum")
}

@(test)
test_frustum_aabb_outside :: proc(t: ^testing.T) {
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  // AABB completely outside the frustum (on +X side)
  aabb := geometry.Aabb{
      linalg.Vector3f32{2, -0.5, -0.5},
      linalg.Vector3f32{3, 0.5, 0.5},
  }
  inside := geometry.frustum_test_aabb(&frustum, aabb)
  testing.expect(t, !inside, "AABB should be outside the frustum")
}

@(test)
test_frustum_aabb_intersect :: proc(t: ^testing.T) {
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  // AABB partially inside the frustum
  aabb := geometry.Aabb{
      linalg.Vector3f32{0.5, -0.5, -0.5},
      linalg.Vector3f32{1.5, 0.5, 0.5},
  }
  inside := geometry.frustum_test_aabb(&frustum, aabb)
  testing.expect(t, inside, "AABB should intersect the frustum")
}

@(test)
test_frustum_sphere_inside :: proc(t: ^testing.T) {
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  center := linalg.Vector3f32{0, 0, 0}
  radius: f32 = 0.5
  inside := geometry.frustum_test_sphere(center, radius, &frustum)
  testing.expect(t, inside, "Sphere should be inside the frustum")
}

@(test)
test_frustum_sphere_outside :: proc(t: ^testing.T) {
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  center := linalg.Vector3f32{2, 0, 0}
  radius: f32 = 0.5
  inside := geometry.frustum_test_sphere(center, radius, &frustum)
  testing.expect(t, !inside, "Sphere should be outside the frustum")
}

@(test)
test_frustum_aabb_perspective_projection :: proc(t: ^testing.T) {
  // Create a perspective projection matrix (fov = 90deg, aspect = 1, near = 1, far = 10)
  fov: f32 = math.PI / 2.0
  aspect: f32 = 1.0
  near: f32 = 0.01
  far: f32 = 10.0
  proj := linalg.matrix4_perspective(fov, aspect, near, far)
  frustum := geometry.make_frustum(proj)
  // AABB fully inside the frustum (centered at origin, small size)
  aabb := geometry.Aabb{
      linalg.Vector3f32{-0.5, -0.5, -2.0},
      linalg.Vector3f32{0.5, 0.5, -1.5},
  }
  inside := geometry.frustum_test_aabb(&frustum, aabb)
  testing.expect(t, inside, "AABB should be inside the perspective frustum")
  // AABB outside the frustum (behind the camera)
  aabb2 := geometry.Aabb{
      linalg.Vector3f32{-0.5, -0.5, 1.0},
      linalg.Vector3f32{0.5, 0.5, 2.0},
  }
  inside2 := geometry.frustum_test_aabb(&frustum, aabb2)
  testing.expect(
    t,
    !inside2,
    "AABB behind the camera should be outside the frustum",
  )
}
