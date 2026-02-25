package geometry

import "core:testing"
import "core:log"
import "core:math/linalg"
import "core:math"

// @(test)
test_matrix_indexing :: proc(t: ^testing.T) {
  fov := f32(math.PI/3.0)
  aspect := f32(1.0)
  near := f32(0.1)
  far := f32(100.0)
  proj := linalg.matrix4_perspective(fov, aspect, near, far)
  expected_P22 := -(far + near) / (far - near)
  expected_P32 := -2.0 * far * near / (far - near)
  expected_P23 := f32(-1.0)
  // For perspective projection, expected values are:
  // P[2,2] should be -(f+n)/(f-n)
  // P[2,3] should be -2*f*n/(f-n) (the depth offset term)
  // P[3,2] should be -1 (the perspective divide)
  testing.expect(t, abs(proj[2][2] - expected_P22) < 0.001, "proj[2][2] should be -(f+n)/(f-n)")
  testing.expect(t, abs(proj[3][2] - expected_P32) < 0.001, "proj[2][3] should be -2fn/(f-n)")
  testing.expect(t, abs(proj[2][3] - expected_P23) < 0.001, "proj[3][2] should be -1")
  testing.expect(t, abs(proj[2,2] - expected_P22) < 0.001, "proj[2,2] should be -(f+n)/(f-n)")
  testing.expect(t, abs(proj[2,3] - expected_P32) < 0.001, "proj[2,3] should be -2fn/(f-n)")
  testing.expect(t, abs(proj[3,2] - expected_P23) < 0.001, "proj[3,2] should be -1")
  // Test point at view_z = -10
  view_z := f32(-10.0)
  ndc_2 := (proj[2,2] * view_z + proj[2,3]) / -view_z
  // Test with the full clip-space transformation
  clip_pos := proj * linalg.Vector4f32{0, 0, view_z, 1}
  ndc_correct := clip_pos.z / clip_pos.w
  testing.expect(t, abs(ndc_2 - ndc_correct) < 0.001, "Method 2 (using proj[2,3]) should match full multiply")
}

@(test)
test_matrix_mul_order_right_operand_first :: proc(t: ^testing.T) {
    translate_x10 := linalg.matrix4_translate([3]f32{10.0, 0, 0})
    scale_2x := linalg.matrix4_scale([3]f32{2.0, 2.0, 2.0})
    rotate_45 := linalg.matrix4_rotate(math.PI * 0.25, [3]f32{0, 1, 0})
    point := [4]f32{0,0,0,1}
    // translate to x=10, rotate from origin (x is now aprox 7), then scale 2x (x is now aprox 14)
    transform := scale_2x * rotate_45 * translate_x10
    log.infof("transform matrix in memory %v", transmute([16]f32)transform)
    transformed := transform * point
    expected_transformed := [4]f32{14.1421356, 0, -14.1421356, 1}
    testing.expect(t, linalg.distance(transformed, expected_transformed) < 0.001)
    // scale, then rotate in place, then translate to x = 10, x must be 10
    transform_alt := translate_x10 * rotate_45 * scale_2x
    log.infof("transform matrix in memory (alt) %v", transmute([16]f32)transform_alt)
    transformed_alt := transform_alt * point
    expected_transformed_alt := [4]f32{10, 0, 0, 1}
    testing.expect(t, linalg.distance(transformed_alt, expected_transformed_alt) < 0.001)
}

@(test)
test_projection_matrix :: proc(t: ^testing.T) {
    fov := f32(math.PI / 3.0) // 60 degrees
    aspect := f32(1.0)
    near := f32(0.1)
    far := f32(100.0)
    proj := linalg.matrix4_perspective(fov, aspect, near, far)
    log.infof("matrix4_perspective matrix in memory %v", transmute([16]f32)proj)
    // Expected values for RH GL-style perspective projection
    expected_P22 := -(far + near) / (far - near)
    expected_P32 := -2.0 * far * near / (far - near)
    expected_P23 := f32(-1.0)
    // Test matrix elements
    testing.expect(t, abs(proj[2][2] - expected_P22) < 0.001, "proj[2][2] should be -(f+n)/(f-n)")
    testing.expect(t, abs(proj[3][2] - expected_P32) < 0.001, "proj[3][2] should be -2fn/(f-n)")
    testing.expect(t, abs(proj[2][3] - expected_P23) < 0.001, "proj[2][3] should be -1")
    // Test point transformation at view_z = -10
    view_z := f32(-10.0)
    clip_pos := proj * linalg.Vector4f32{0, 0, view_z, 1}
    ndc_z := clip_pos.z / clip_pos.w
    log.infof("NDC z for view_z=%f: %f", view_z, ndc_z)
}

@(test)
test_view_matrix :: proc(t: ^testing.T) {
    eye_pos := [3]f32{3.0, 4.0, 5.0}
    focus_pos := [3]f32{0.0, 0.0, 0.0}
    up_dir := [3]f32{0.0, 1.0, 0.0}
    view := linalg.matrix4_look_at(eye_pos, focus_pos, up_dir)
    log.infof("matrix4_look_at matrix in memory %v", transmute([16]f32)view)

    // Transform a point at origin - should move to eye position in view space
    origin := [4]f32{0.0, 0.0, 0.0, 1.0}
    view_space_origin := view * origin
    log.infof("Origin in view space: %v", view_space_origin)

    // In view space, the camera looks down -Z, so the origin (which is in front of camera)
    // should have negative Z in view space
    expected_distance := linalg.length(eye_pos - focus_pos)
    actual_distance := abs(view_space_origin.z)
    testing.expect(t, abs(actual_distance - expected_distance) < 0.001, "Distance should match")
}

// @(test)
matrix_multiply_vector :: proc(t: ^testing.T) {
  v := [4]f32{0, 0, 0, 1}
  m := linalg.matrix4_translate_f32({1, 2, 3})
  testing.expect_value(t, m * v, [4]f32{1, 2, 3, 1})
}

// @(test)
matrix_extract_decompose :: proc(t: ^testing.T) {
  translation := [4]f32{1, 2, 3, 1}
  m := linalg.matrix4_translate_f32({1, 2, 3})
  testing.expect_value(t, m[3], translation)
  m = linalg.matrix4_scale_f32({2, 3, 4})
  sx := linalg.length(m[0])
  sy := linalg.length(m[1])
  sz := linalg.length(m[2])
  testing.expect_value(t, sx, 2)
  testing.expect_value(t, sy, 3)
  testing.expect_value(t, sz, 4)
}
