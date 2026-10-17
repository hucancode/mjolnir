#+build !js
#+private
package geometry

import "core:math"
import "core:math/linalg"
import "core:testing"

@(test)
test_qmv_matches_linalg :: proc(t: ^testing.T) {
	q := linalg.quaternion_from_euler_angles_f32(0.7, -1.1, 0.4, .XYZ)
	vecs := [?][3]f32{{1, 0, 0}, {0, 1, 0}, {0, 0, 1}, {1, 2, 3}, {-0.5, 0.25, 4}}
	for v in vecs {
		got := qmv(q, v)
		want := linalg.quaternion128_mul_vector3(q, v)
		diff := linalg.length(got - want)
		testing.expectf(t, diff < 1e-4, "qmv mismatch v=%v: got %v want %v", v, got, want)
	}
}

@(test)
test_qx_qy_qz_match_axis_rotations :: proc(t: ^testing.T) {
	q := linalg.quaternion_from_euler_angles_f32(0.5, -0.8, 0.3, .XYZ)
	x := qx(q)
	y := qy(q)
	z := qz(q)
	wx := linalg.quaternion128_mul_vector3(q, [3]f32{1, 0, 0})
	wy := linalg.quaternion128_mul_vector3(q, [3]f32{0, 1, 0})
	wz := linalg.quaternion128_mul_vector3(q, [3]f32{0, 0, 1})
	testing.expectf(t, linalg.length(x - wx) < 1e-4, "qx mismatch: %v vs %v", x, wx)
	testing.expectf(t, linalg.length(y - wy) < 1e-4, "qy mismatch: %v vs %v", y, wy)
	testing.expectf(t, linalg.length(z - wz) < 1e-4, "qz mismatch: %v vs %v", z, wz)

	// Identity quat returns standard basis
	id := linalg.QUATERNIONF32_IDENTITY
	testing.expect(t, qx(id) == [3]f32{1, 0, 0}, "qx(id) = +X")
	testing.expect(t, qy(id) == [3]f32{0, 1, 0}, "qy(id) = +Y")
	testing.expect(t, qz(id) == [3]f32{0, 0, 1}, "qz(id) = +Z")
}

@(test)
test_decompose_matrix_round_trip :: proc(t: ^testing.T) {
	pos := [3]f32{2, -3, 5}
	rot := linalg.quaternion_from_euler_angle_y_f32(math.PI / 3)
	scl := [3]f32{1.5, 1.5, 1.5}
	m := linalg.matrix4_from_trs_f32(pos, rot, scl)
	got_pos, got_rot, got_scl := decompose_matrix(m)
	testing.expectf(t, linalg.length(got_pos - pos) < 1e-4, "position mismatch: %v", got_pos)
	testing.expectf(t, math.abs(got_scl.x - 1.5) < 1e-4 && math.abs(got_scl.y - 1.5) < 1e-4 && math.abs(got_scl.z - 1.5) < 1e-4,
		"scale mismatch: %v", got_scl)
	// rotation: dot product with original quat should be ±1
	d := got_rot.x * rot.x + got_rot.y * rot.y + got_rot.z * rot.z + got_rot.w * rot.w
	testing.expectf(t, math.abs(math.abs(d) - 1.0) < 1e-3, "rotation mismatch, expected = %v, got = %v, dot=%f", rot, got_rot, d)
}

// ----- bounding_box.odin ---------------------------------------

@(test)
test_aabb_contains_and_point :: proc(t: ^testing.T) {
	outer := Aabb{min = {-1, -1, -1}, max = {1, 1, 1}}
	inside := Aabb{min = {-0.5, -0.5, -0.5}, max = {0.5, 0.5, 0.5}}
	overlap := Aabb{min = {0.5, 0.5, 0.5}, max = {1.5, 1.5, 1.5}}

	testing.expect(t, aabb_contains(outer, inside), "fully inside")
	testing.expect(t, !aabb_contains(outer, overlap), "overlap not contained")
	testing.expect(t, aabb_contains_point(outer, {0, 0, 0}), "origin inside")
	testing.expect(t, aabb_contains_point(outer, {1, 1, 1}), "edge inside")
	testing.expect(t, !aabb_contains_point(outer, {2, 0, 0}), "outside x")
}

@(test)
test_aabb_center_size_surface :: proc(t: ^testing.T) {
	box := Aabb{min = {-2, -1, -3}, max = {4, 5, 7}}
	testing.expect(t, aabb_center(box) == [3]f32{1, 2, 2}, "center")
	testing.expect(t, aabb_size(box) == [3]f32{6, 6, 10}, "size")
	// surface = 2 * (6*6 + 6*10 + 10*6) = 2 * 156 = 312
	testing.expect(t, aabb_surface_area(box) == 312, "surface area")
}

@(test)
test_aabb_sphere_intersects :: proc(t: ^testing.T) {
	box := Aabb{min = {0, 0, 0}, max = {1, 1, 1}}
	testing.expect(t, aabb_sphere_intersects(box, {0.5, 0.5, 0.5}, 0.1), "sphere inside box")
	testing.expect(t, aabb_sphere_intersects(box, {1.5, 0.5, 0.5}, 0.6), "sphere overlaps face")
	testing.expect(t, !aabb_sphere_intersects(box, {3, 3, 3}, 0.5), "sphere far away")
}
