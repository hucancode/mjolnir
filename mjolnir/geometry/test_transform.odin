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
	got := decompose_matrix(m)
	testing.expectf(t, linalg.length(got.position - pos) < 1e-4, "position mismatch: %v", got.position)
	testing.expectf(t, math.abs(got.scale.x - 1.5) < 1e-4 && math.abs(got.scale.y - 1.5) < 1e-4 && math.abs(got.scale.z - 1.5) < 1e-4,
		"scale mismatch: %v", got.scale)
	// rotation: dot product with original quat should be ±1
	d := got.rotation.x * rot.x + got.rotation.y * rot.y + got.rotation.z * rot.z + got.rotation.w * rot.w
	testing.expectf(t, math.abs(math.abs(d) - 1.0) < 1e-3, "rotation mismatc, expected = %v, got = %v, dot=%f", rot, got.rotation, d)
}

@(test)
test_update_local_only_when_dirty :: proc(t: ^testing.T) {
	tr := TRANSFORM_IDENTITY
	tr.position = {7, 0, 0}
	tr.is_dirty = true
	changed := update_local(&tr)
	testing.expect(t, changed && !tr.is_dirty, "first update applies + clears flag")
	testing.expectf(t, math.abs(tr.local_matrix[3].x - 7.0) < 1e-4, "matrix translation in column 3")

	again := update_local(&tr)
	testing.expect(t, !again, "non-dirty update returns false")
}

@(test)
test_update_world_composes_parent :: proc(t: ^testing.T) {
	tr := TRANSFORM_IDENTITY
	tr.local_matrix = linalg.matrix4_translate_f32({1, 0, 0})
	parent := linalg.matrix4_translate_f32({10, 0, 0})
	update_world(&tr, parent)
	testing.expectf(t, math.abs(tr.world_matrix[3].x - 11.0) < 1e-4,
		"world should be parent * local, got x=%f", tr.world_matrix[3].x)
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
test_aabb_center_size_surface_volume :: proc(t: ^testing.T) {
	box := Aabb{min = {-2, -1, -3}, max = {4, 5, 7}}
	testing.expect(t, aabb_center(box) == [3]f32{1, 2, 2}, "center")
	testing.expect(t, aabb_size(box) == [3]f32{6, 6, 10}, "size")
	// surface = 2 * (6*6 + 6*10 + 10*6) = 2 * 156 = 312
	testing.expect(t, aabb_surface_area(box) == 312, "surface area")
	// volume = 6 * 6 * 10 = 360
	testing.expect(t, aabb_volume(box) == 360, "volume")
}

@(test)
test_aabb_sphere_intersects :: proc(t: ^testing.T) {
	box := Aabb{min = {0, 0, 0}, max = {1, 1, 1}}
	testing.expect(t, aabb_sphere_intersects(box, {0.5, 0.5, 0.5}, 0.1), "sphere inside box")
	testing.expect(t, aabb_sphere_intersects(box, {1.5, 0.5, 0.5}, 0.6), "sphere overlaps face")
	testing.expect(t, !aabb_sphere_intersects(box, {3, 3, 3}, 0.5), "sphere far away")
}

@(test)
test_distance_point_aabb :: proc(t: ^testing.T) {
	box := Aabb{min = {0, 0, 0}, max = {1, 1, 1}}
	testing.expect(t, distance_point_aabb({0.5, 0.5, 0.5}, box) == 0, "interior dist 0")
	d := distance_point_aabb({3, 0.5, 0.5}, box)
	testing.expectf(t, math.abs(d - 2.0) < 1e-4, "exterior dist=2 expected, got %f", d)
}

@(test)
test_closest_point_on_segment_clamps :: proc(t: ^testing.T) {
	a := [3]f32{0, 0, 0}
	b := [3]f32{10, 0, 0}
	testing.expect(t, closest_point_on_segment({5, 1, 0}, a, b) == [3]f32{5, 0, 0}, "midpoint projection")
	testing.expect(t, closest_point_on_segment({-3, 0, 0}, a, b) == a, "before start clamps to a")
	testing.expect(t, closest_point_on_segment({99, 0, 0}, a, b) == b, "after end clamps to b")
}

@(test)
test_segment_segment_closest_points_skew :: proc(t: ^testing.T) {
	// X-axis segment vs Y-axis segment, separated by 2 units in Z
	a0 := [3]f32{-1, 0, 0}
	a1 := [3]f32{1, 0, 0}
	b0 := [3]f32{0, -1, 2}
	b1 := [3]f32{0, 1, 2}
	pa, pb, _, _ := segment_segment_closest_points(a0, a1, b0, b1)
	testing.expectf(t, linalg.length(pa - [3]f32{0, 0, 0}) < 1e-4, "closest on A is origin, got %v", pa)
	testing.expectf(t, linalg.length(pb - [3]f32{0, 0, 2}) < 1e-4, "closest on B is (0,0,2), got %v", pb)
}

@(test)
test_segment_segment_closest_points_degenerate :: proc(t: ^testing.T) {
	// Both segments degenerate to points
	pa, pb, s, ti := segment_segment_closest_points({1, 2, 3}, {1, 2, 3}, {4, 5, 6}, {4, 5, 6})
	testing.expect(t, pa == [3]f32{1, 2, 3} && pb == [3]f32{4, 5, 6} && s == 0 && ti == 0,
		"both points return as-is")
}

@(test)
test_point_polygon_distance_inside_outside :: proc(t: ^testing.T) {
	square := [][3]f32{{0, 0, 0}, {2, 0, 0}, {2, 0, 2}, {0, 0, 2}}
	d_in := point_polygon_distance({1, 0, 1}, square)
	testing.expect(t, d_in < 0, "interior must be negative")

	d_edge := point_polygon_distance({1, 0, 0}, square)
	testing.expectf(t, math.abs(d_edge) < 1e-4, "edge ~0 expected, got %f", d_edge)

	d_out := point_polygon_distance({3, 0, 1}, square)
	testing.expectf(t, math.abs(d_out - 1.0) < 1e-4, "1 unit outside expected, got %f", d_out)
}

@(test)
test_in_circumcircle_xz_plane :: proc(t: ^testing.T) {
	// triangle on XZ plane: (0,0,0), (4,0,0), (0,0,4)
	// circumcircle center = (2,0,2), radius = 2*sqrt(2)
	a := [3]f32{0, 0, 0}
	b := [3]f32{4, 0, 0}
	c := [3]f32{0, 0, 4}
	testing.expect(t, in_circumcircle({2, 0, 2}, a, b, c), "center inside")
	testing.expect(t, !in_circumcircle({-5, 0, -5}, a, b, c), "far outside")
}
