package tests

import "../mjolnir/geometry"
import "core:math"
import linalg "core:math/linalg"
import "core:testing"
import "core:log"

@(test)
test_frustum_aabb_inside :: proc(t: ^testing.T) {
  // Create a simple orthographic frustum centered at origin
  // For simplicity, use identity matrix (frustum from -1 to 1 in all axes)
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  // AABB fully inside the frustum
  aabb := geometry.Aabb {
    [3]f32{-0.5, -0.5, -0.5},
    [3]f32{0.5, 0.5, 0.5},
  }
  inside := geometry.frustum_test_aabb(frustum, aabb)
  testing.expect(t, inside, "AABB should be inside the frustum")
}

@(test)
test_frustum_aabb_outside :: proc(t: ^testing.T) {
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  // AABB completely outside the frustum (on +X side)
  aabb := geometry.Aabb {
    [3]f32{2, -0.5, -0.5},
    [3]f32{3, 0.5, 0.5},
  }
  inside := geometry.frustum_test_aabb(frustum, aabb)
  testing.expect(t, !inside, "AABB should be outside the frustum")
}

@(test)
test_frustum_aabb_intersect :: proc(t: ^testing.T) {
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  // AABB partially inside the frustum
  aabb := geometry.Aabb {
    [3]f32{0.5, -0.5, -0.5},
    [3]f32{1.5, 0.5, 0.5},
  }
  inside := geometry.frustum_test_aabb(frustum, aabb)
  testing.expect(t, inside, "AABB should intersect the frustum")
}

@(test)
test_frustum_sphere_inside :: proc(t: ^testing.T) {
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  center := [3]f32{0, 0, 0}
  radius: f32 = 0.5
  inside := geometry.frustum_test_sphere(center, radius, &frustum)
  testing.expect(t, inside, "Sphere should be inside the frustum")
}

@(test)
test_frustum_sphere_outside :: proc(t: ^testing.T) {
  m := linalg.MATRIX4F32_IDENTITY
  frustum := geometry.make_frustum(m)
  center := [3]f32{2, 0, 0}
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
  aabb := geometry.Aabb {
    [3]f32{-0.5, -0.5, -2.0},
    [3]f32{0.5, 0.5, -1.5},
  }
  inside := geometry.frustum_test_aabb(frustum, aabb)
  testing.expect(t, inside, "AABB should be inside the perspective frustum")
  // AABB outside the frustum (behind the camera)
  aabb2 := geometry.Aabb {
    [3]f32{-0.5, -0.5, 1.0},
    [3]f32{0.5, 0.5, 2.0},
  }
  inside2 := geometry.frustum_test_aabb(frustum, aabb2)
  testing.expect(
    t,
    !inside2,
    "AABB behind the camera should be outside the frustum",
  )
}

@(test)
test_frustum_camera_perspective :: proc(t: ^testing.T) {
  // Create a realistic camera setup
  camera_pos := [3]f32{0, 0, 0}
  camera_target := [3]f32{0, 0, -1}  // Looking down -Z
  camera_up := [3]f32{0, 1, 0}       // Y is up

  // Create view matrix (camera looking down -Z axis)
  view := linalg.matrix4_look_at(camera_pos, camera_target, camera_up)

  // Create perspective projection (90 degree FOV, aspect 1:1, near=0.1, far=100)
  fov: f32 = math.PI / 2.0  // 90 degrees
  aspect: f32 = 1.0
  near: f32 = 0.1
  far: f32 = 100.0
  proj := linalg.matrix4_perspective(fov, aspect, near, far)

  // Create combined view-projection matrix
  view_proj := proj * view
  frustum := geometry.make_frustum(view_proj)

  log.infof("Camera at %v, looking at %v", camera_pos, camera_target)
  log.infof("View matrix:\n%v", view)
  log.infof("Projection matrix:\n%v", proj)
  log.infof("View-Projection matrix:\n%v", view_proj)

  // Test 1: Object in front of camera (should be visible)
  aabb_front := geometry.Aabb {
    [3]f32{-1, -1, -5},  // In front of camera
    [3]f32{1, 1, -3},
  }
  inside_front := geometry.frustum_test_aabb(frustum, aabb_front)
  testing.expect(t, inside_front, "AABB in front of camera should be visible")
  log.infof("Front AABB %v: %v", aabb_front, inside_front)

  // Test 2: Object behind camera (should NOT be visible)
  aabb_behind := geometry.Aabb {
    [3]f32{-1, -1, 1},   // Behind camera
    [3]f32{1, 1, 3},
  }
  inside_behind := geometry.frustum_test_aabb(frustum, aabb_behind)
  testing.expect(t, !inside_behind, "AABB behind camera should NOT be visible")
  log.infof("Behind AABB %v: %v", aabb_behind, inside_behind)

  // Test 3: Object to the right of camera (should NOT be visible with 90° FOV)
  aabb_right := geometry.Aabb {
    [3]f32{10, -1, -5},  // Far to the right
    [3]f32{12, 1, -3},
  }
  inside_right := geometry.frustum_test_aabb(frustum, aabb_right)
  testing.expect(t, !inside_right, "AABB far to the right should NOT be visible")
  log.infof("Right AABB %v: %v", aabb_right, inside_right)

  // Test 4: Object to the left of camera (should NOT be visible with 90° FOV)
  aabb_left := geometry.Aabb {
    [3]f32{-12, -1, -5}, // Far to the left
    [3]f32{-10, 1, -3},
  }
  inside_left := geometry.frustum_test_aabb(frustum, aabb_left)
  testing.expect(t, !inside_left, "AABB far to the left should NOT be visible")
  log.infof("Left AABB %v: %v", aabb_left, inside_left)

  // Test 5: Object above camera (should NOT be visible with 90° FOV)
  aabb_above := geometry.Aabb {
    [3]f32{-1, 10, -5},  // Far above
    [3]f32{1, 12, -3},
  }
  inside_above := geometry.frustum_test_aabb(frustum, aabb_above)
  testing.expect(t, !inside_above, "AABB far above should NOT be visible")
  log.infof("Above AABB %v: %v", aabb_above, inside_above)

  // Test 6: Object below camera (should NOT be visible with 90° FOV)
  aabb_below := geometry.Aabb {
    [3]f32{-1, -12, -5}, // Far below
    [3]f32{1, -10, -3},
  }
  inside_below := geometry.frustum_test_aabb(frustum, aabb_below)
  testing.expect(t, !inside_below, "AABB far below should NOT be visible")
  log.infof("Below AABB %v: %v", aabb_below, inside_below)

  // Test 7: Object at edge of frustum (should be visible)
  // With 90° FOV, at distance 5, the half-width should be tan(45°) * 5 = 5
  aabb_edge := geometry.Aabb {
    [3]f32{4, 4, -5},    // Near the edge
    [3]f32{4.5, 4.5, -4.5},
  }
  inside_edge := geometry.frustum_test_aabb(frustum, aabb_edge)
  testing.expect(t, inside_edge, "AABB at edge of frustum should be visible")
  log.infof("Edge AABB %v: %v", aabb_edge, inside_edge)

  // Test 8: Object too far away (beyond far plane)
  aabb_far := geometry.Aabb {
    [3]f32{-1, -1, -150}, // Beyond far plane
    [3]f32{1, 1, -120},
  }
  inside_far := geometry.frustum_test_aabb(frustum, aabb_far)
  testing.expect(t, !inside_far, "AABB beyond far plane should NOT be visible")
  log.infof("Far AABB %v: %v", aabb_far, inside_far)

  // Test 9: Object too close (before near plane)
  aabb_near := geometry.Aabb {
    [3]f32{-0.01, -0.01, -0.05}, // Before near plane
    [3]f32{0.01, 0.01, -0.01},
  }
  inside_near := geometry.frustum_test_aabb(frustum, aabb_near)
  testing.expect(t, !inside_near, "AABB before near plane should NOT be visible")
  log.infof("Near AABB %v: %v", aabb_near, inside_near)
}

@(test)
test_frustum_camera_orthographic :: proc(t: ^testing.T) {
  // Test with orthographic projection
  camera_pos := [3]f32{0, 0, 0}
  camera_target := [3]f32{0, 0, -1}
  camera_up := [3]f32{0, 1, 0}

  view := linalg.matrix4_look_at(camera_pos, camera_target, camera_up)

  // Orthographic projection: left, right, bottom, top, near, far
  proj := linalg.matrix_ortho3d_f32(-5, 5, -5, 5, 0.1, 100)

  view_proj := proj * view
  frustum := geometry.make_frustum(view_proj)

  log.infof("Orthographic camera test")

  // Test 1: Object within orthographic bounds (should be visible)
  aabb_inside := geometry.Aabb {
    [3]f32{-3, -3, -10},
    [3]f32{3, 3, -5},
  }
  inside := geometry.frustum_test_aabb(frustum, aabb_inside)
  testing.expect(t, inside, "AABB within orthographic bounds should be visible")
  log.infof("Inside ortho AABB %v: %v", aabb_inside, inside)

  // Test 2: Object outside orthographic bounds (should NOT be visible)
  aabb_outside := geometry.Aabb {
    [3]f32{-10, -10, -10},
    [3]f32{-7, -7, -5},
  }
  outside := geometry.frustum_test_aabb(frustum, aabb_outside)
  testing.expect(t, !outside, "AABB outside orthographic bounds should NOT be visible")
  log.infof("Outside ortho AABB %v: %v", aabb_outside, outside)
}

@(test)
test_frustum_camera_moved :: proc(t: ^testing.T) {
  // Test camera moved to a different position
  camera_pos := [3]f32{10, 5, 10}
  camera_target := [3]f32{0, 0, 0}    // Looking at origin
  camera_up := [3]f32{0, 1, 0}

  view := linalg.matrix4_look_at(camera_pos, camera_target, camera_up)

  fov: f32 = math.PI / 3.0  // 60 degrees
  aspect: f32 = 16.0 / 9.0  // Widescreen aspect ratio
  near: f32 = 0.1
  far: f32 = 100.0
  proj := linalg.matrix4_perspective(fov, aspect, near, far)

  view_proj := proj * view
  frustum := geometry.make_frustum(view_proj)

  log.infof("Moved camera test: camera at %v looking at %v", camera_pos, camera_target)

  // Test 1: Object at origin (should be visible since camera is looking at it)
  aabb_origin := geometry.Aabb {
    [3]f32{-1, -1, -1},
    [3]f32{1, 1, 1},
  }
  at_origin := geometry.frustum_test_aabb(frustum, aabb_origin)
  testing.expect(t, at_origin, "AABB at origin should be visible")
  log.infof("Origin AABB %v: %v", aabb_origin, at_origin)

  // Test 2: Object behind camera (should NOT be visible)
  aabb_behind_moved := geometry.Aabb {
    [3]f32{15, 3, 15},   // Behind the moved camera
    [3]f32{17, 7, 17},
  }
  behind_moved := geometry.frustum_test_aabb(frustum, aabb_behind_moved)
  testing.expect(t, !behind_moved, "AABB behind moved camera should NOT be visible")
  log.infof("Behind moved camera AABB %v: %v", aabb_behind_moved, behind_moved)
}

@(test)
test_frustum_sphere_camera :: proc(t: ^testing.T) {
  // Test sphere frustum culling with camera
  camera_pos := [3]f32{0, 0, 0}
  camera_target := [3]f32{0, 0, -1}
  camera_up := [3]f32{0, 1, 0}

  view := linalg.matrix4_look_at(camera_pos, camera_target, camera_up)
  proj := linalg.matrix4_perspective_f32(math.PI / 2.0, 1.0, 0.1, 100.0)

  view_proj := proj * view
  frustum := geometry.make_frustum(view_proj)

  // Test 1: Sphere in front of camera
  sphere_center := [3]f32{0, 0, -5}
  sphere_radius: f32 = 1.0
  inside_front := geometry.frustum_test_sphere(sphere_center, sphere_radius, &frustum)
  testing.expect(t, inside_front, "Sphere in front of camera should be visible")
  log.infof("Front sphere at %v with radius %v: %v", sphere_center, sphere_radius, inside_front)

  // Test 2: Sphere behind camera
  sphere_behind := [3]f32{0, 0, 5}
  inside_behind := geometry.frustum_test_sphere(sphere_behind, sphere_radius, &frustum)
  testing.expect(t, !inside_behind, "Sphere behind camera should NOT be visible")
  log.infof("Behind sphere at %v with radius %v: %v", sphere_behind, sphere_radius, inside_behind)

  // Test 3: Large sphere that intersects frustum
  large_sphere_center := [3]f32{10, 0, -5}
  large_sphere_radius: f32 = 8.0  // Large enough to intersect frustum
  inside_large := geometry.frustum_test_sphere(large_sphere_center, large_sphere_radius, &frustum)
  testing.expect(t, inside_large, "Large sphere intersecting frustum should be visible")
  log.infof("Large sphere at %v with radius %v: %v", large_sphere_center, large_sphere_radius, inside_large)
}
