package geometry

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"

// Test constants
// Helper to compare floats with epsilon
approx_equal :: proc(a, b: f32, epsilon: f32 = math.F32_EPSILON) -> bool {
  return math.abs(a - b) < epsilon
}

// Helper to compare vectors with epsilon
vec3_approx_equal :: proc(
  a, b: [3]f32,
  epsilon: f32 = math.F32_EPSILON,
) -> bool {
  return(
    approx_equal(a.x, b.x, epsilon) &&
    approx_equal(a.y, b.y, epsilon) &&
    approx_equal(a.z, b.z, epsilon) \
  )
}

@(test)
test_vec2f_perp :: proc(t: ^testing.T) {
  // Test perpendicular vectors: a=(0,0), b=(1,0), c=(0,1) -> cross product = 1
  result := perpendicular_cross_2d({0, 0, 0}, {1, 0, 0}, {0, 0, 1})
  testing.expect_value(t, result, f32(1))
  // Test parallel vectors: a=(0,0), b=(1,0), c=(1,0) -> cross product = 0
  result = perpendicular_cross_2d({0, 0, 0}, {1, 0, 0}, {1, 0, 0})
  testing.expect_value(t, result, f32(0))
  // Test arbitrary vectors: a=(0,0), b=(3,4), c=(1,2) -> (3-0)*(2-0) - (4-0)*(1-0) = 6-4 = 2
  result = perpendicular_cross_2d({0, 0, 0}, {3, 0, 4}, {1, 0, 2})
  testing.expect_value(t, result, f32(2))
}

@(test)
test_overlap_bounds :: proc(t: ^testing.T) {
  // Test overlapping bounds
  amin1 := [3]f32{0, 0, 0}
  amax1 := [3]f32{10, 10, 10}
  bmin1 := [3]f32{5, 5, 5}
  bmax1 := [3]f32{15, 15, 15}
  testing.expect(
    t,
    overlap_bounds(amin1, amax1, bmin1, bmax1),
    "Bounds should overlap",
  )
  // Test non-overlapping bounds
  bmin2 := [3]f32{15, 15, 15}
  bmax2 := [3]f32{20, 20, 20}
  testing.expect(
    t,
    !overlap_bounds(amin1, amax1, bmin2, bmax2),
    "Bounds should not overlap",
  )
  // Test touching bounds (edge case)
  bmin3 := [3]f32{10, 10, 10}
  bmax3 := [3]f32{20, 20, 20}
  testing.expect(
    t,
    overlap_bounds(amin1, amax1, bmin3, bmax3),
    "Touching bounds should overlap",
  )
}

@(test)
test_overlap_quantized_bounds :: proc(t: ^testing.T) {
  // Test overlapping quantized bounds
  amin1 := [3]i32{0, 0, 0}
  amax1 := [3]i32{10, 10, 10}
  bmin1 := [3]i32{5, 5, 5}
  bmax1 := [3]i32{15, 15, 15}
  testing.expect(
    t,
    overlap_quantized_bounds(amin1, amax1, bmin1, bmax1),
    "Quantized bounds should overlap",
  )
  // Test non-overlapping quantized bounds
  bmin2 := [3]i32{15, 15, 15}
  bmax2 := [3]i32{20, 20, 20}
  testing.expect(
    t,
    !overlap_quantized_bounds(amin1, amax1, bmin2, bmax2),
    "Quantized bounds should not overlap",
  )
}

@(test)
test_triangle_area_2d :: proc(t: ^testing.T) {
  // Test right triangle
  a := [3]f32{0, 0, 0}
  b := [3]f32{3, 0, 0}
  c := [3]f32{0, 0, 4}
  area := triangle_area_2d(a, b, c)
  testing.expect(t, approx_equal(area, 6.0), "Triangle area should be 6")
  area = triangle_area_2d(a, c, b)
  testing.expect(t, approx_equal(area, 6.0), "Triangle area should be 6")
  // Test degenerate triangle (collinear points)
  d := [3]f32{0, 0, 0}
  e := [3]f32{1, 0, 0}
  f := [3]f32{2, 0, 0}
  area2 := triangle_area_2d(d, e, f)
  testing.expect(
    t,
    approx_equal(area2, 0.0),
    "Degenerate triangle area should be 0",
  )
}

@(test)
test_point_in_polygon_2d :: proc(t: ^testing.T) {
  // Test square polygon
  square := [][3]f32{{0, 0, 0}, {10, 0, 0}, {10, 0, 10}, {0, 0, 10}}
  // Test point inside
  pt_inside := [3]f32{5, 0, 5}
  testing.expect(
    t,
    point_in_polygon_2d(pt_inside, square),
    "Point should be inside square",
  )
  // Test point outside
  pt_outside := [3]f32{15, 0, 15}
  testing.expect(
    t,
    !point_in_polygon_2d(pt_outside, square),
    "Point should be outside square",
  )
  // Test point on edge
  pt_edge := [3]f32{5, 0, 0}
  edge_result := point_in_polygon_2d(pt_edge, square)
  if edge_result {
    fmt.printf("Point on edge returned %v, expected false\n", edge_result)
  }
  testing.expect(t, !edge_result, "Point on edge should be considered outside")
  // Test point on vertex
  pt_vertex := [3]f32{0, 0, 0}
  testing.expect(
    t,
    !point_in_polygon_2d(pt_vertex, square),
    "Point on vertex should be considered outside",
  )
  // Test concave polygon
  // Drawing in XZ plane:
  // (0,10)---(5,5)---(10,10)
  //   |       /          |
  //   |      /           |
  //   |     /            |
  // (0,0)-------------(10,0)
  concave := [][3]f32 {
    {0, 0, 0},
    {10, 0, 0},
    {10, 0, 10},
    {5, 0, 5}, // Concave point - creates notch
    {0, 0, 10},
  }
  // Point at (2, 4.5) is clearly inside the polygon (avoiding edge case at z=5)
  pt_concave_in := [3]f32{2, 0, 4.5}
  in_result := point_in_polygon_2d(pt_concave_in, concave)
  if !in_result {
    fmt.printf("Point (2,0,4.5) returned %v, expected true\n", in_result)
  }
  testing.expect(t, in_result, "Point should be inside concave polygon")
  // Test a point that's clearly outside
  // Point (15, 5) is outside the polygon entirely
  pt_concave_out := [3]f32{15, 0, 5}
  out_result := point_in_polygon_2d(pt_concave_out, concave)
  if out_result {
    fmt.printf("Point (15,0,5) returned %v, expected false\n", out_result)
  }
  testing.expect(
    t,
    !out_result,
    "Point at (15,5) should be outside concave polygon",
  )
}

@(test)
test_intersect_segment_triangle :: proc(t: ^testing.T) {
  // Define a triangle in XZ plane at Y=0
  a := [3]f32{0, 0, 0}
  b := [3]f32{10, 0, 0}
  c := [3]f32{0, 0, 10}
  // Test segment that intersects triangle
  sp1 := [3]f32{2, 5, 2}
  sq1 := [3]f32{2, -5, 2}
  hit1, t1 := intersect_segment_triangle(sp1, sq1, a, b, c)
  testing.expect(t, hit1, "Segment should intersect triangle")
  testing.expect(t, approx_equal(t1, 0.5), "Intersection should be at t=0.5")
  // Test segment that misses triangle
  sp2 := [3]f32{20, 5, 20}
  sq2 := [3]f32{20, -5, 20}
  hit2, _ := intersect_segment_triangle(sp2, sq2, a, b, c)
  testing.expect(t, !hit2, "Segment should miss triangle")
  // Test segment parallel to triangle
  sp3 := [3]f32{2, 0, 2}
  sq3 := [3]f32{5, 0, 5}
  hit3, _ := intersect_segment_triangle(sp3, sq3, a, b, c)
  testing.expect(t, !hit3, "Parallel segment should not intersect")
  // Test segment that starts inside and goes out
  sp4 := [3]f32{2, -1, 2}
  sq4 := [3]f32{2, 1, 2}
  hit4, t4 := intersect_segment_triangle(sp4, sq4, a, b, c)
  testing.expect(t, hit4, "Segment starting below should intersect")
  testing.expect(t, approx_equal(t4, 0.5), "Intersection should be at t=0.5")
}

@(test)
test_closest_point_on_triangle :: proc(t: ^testing.T) {
  // Define a triangle
  a := [3]f32{0, 0, 0}
  b := [3]f32{10, 0, 0}
  c := [3]f32{0, 0, 10}
  // Test point closest to vertex A
  p1 := [3]f32{-5, 5, -5}
  closest1 := closest_point_on_triangle(p1, a, b, c)
  testing.expect(
    t,
    vec3_approx_equal(closest1, a),
    "Closest point should be vertex A",
  )
  // Test point closest to vertex B
  p2 := [3]f32{15, 5, -5}
  closest2 := closest_point_on_triangle(p2, a, b, c)
  testing.expect(
    t,
    vec3_approx_equal(closest2, b),
    "Closest point should be vertex B",
  )
  // Test point closest to vertex C
  p3 := [3]f32{-5, 5, 15}
  closest3 := closest_point_on_triangle(p3, a, b, c)
  testing.expect(
    t,
    vec3_approx_equal(closest3, c),
    "Closest point should be vertex C",
  )
  // Test point closest to edge AB
  p4 := [3]f32{5, 5, -5}
  closest4 := closest_point_on_triangle(p4, a, b, c)
  expected4 := [3]f32{5, 0, 0}
  testing.expect(
    t,
    vec3_approx_equal(closest4, expected4),
    "Closest point should be on edge AB",
  )
  // Test point inside triangle (projects to itself)
  p5 := [3]f32{2, 0, 2}
  closest5 := closest_point_on_triangle(p5, a, b, c)
  testing.expect(
    t,
    vec3_approx_equal(closest5, p5, 1e-6),
    "Point inside triangle should project to itself",
  )
}

@(test)
test_dist_point_segment_sq_2d :: proc(t: ^testing.T) {
  // Test point on segment
  pt1 := [3]f32{5, 0, 0}
  p := [3]f32{0, 0, 0}
  q := [3]f32{10, 0, 0}
  dist1, _ := point_segment_distance2_2d(pt1, p, q)
  testing.expect(
    t,
    approx_equal(dist1, 0.0),
    "Distance to point on segment should be 0",
  )
  // Test point perpendicular to segment
  pt2 := [3]f32{5, 0, 5}
  dist2, _ := point_segment_distance2_2d(pt2, p, q)
  testing.expect(t, approx_equal(dist2, 25.0), "Squared distance should be 25")
  // Test point beyond segment end
  pt3 := [3]f32{15, 0, 0}
  dist3, _ := point_segment_distance2_2d(pt3, p, q)
  testing.expect(
    t,
    approx_equal(dist3, 25.0),
    "Squared distance to segment end should be 25",
  )
  // Test degenerate segment (point)
  pt4 := [3]f32{3, 0, 4}
  dist4, _ := point_segment_distance2_2d(pt4, p, p)
  testing.expect(
    t,
    approx_equal(dist4, 25.0),
    "Squared distance to degenerate segment should be 25",
  )
}

@(test)
test_dist_point_segment_sq :: proc(t: ^testing.T) {
  // Test 3D point-segment distance
  pt1 := [3]f32{5, 5, 0}
  p := [3]f32{0, 0, 0}
  q := [3]f32{10, 0, 0}
  dist1, _ := point_segment_distance2_2d(pt1, p, q)
  // In 2D (XZ plane), pt1={5,5,0} projects to {5,0} and segment is {0,0} to {10,0}
  // Closest point on segment is {5,0}, distance in XZ is 0
  testing.expect(
    t,
    approx_equal(dist1, 0.0),
    "2D squared distance in XZ plane should be 0",
  )
  // Test point with Y component
  pt2 := [3]f32{5, 3, 4}
  dist2, _ := point_segment_distance2_2d(pt2, p, q)
  // In 2D (XZ plane), pt2={5,3,4} projects to {5,4} and segment is {0,0} to {10,0}
  // Closest point on segment is {5,0}, distance in XZ is 4^2 = 16
  testing.expect(
    t,
    approx_equal(dist2, 16.0),
    "2D squared distance in XZ plane should be 16",
  )
}

@(test)
test_calc_poly_normal :: proc(t: ^testing.T) {
  // Test square in XZ plane
  // Use counter-clockwise winding when viewed from above for upward normal
  square := [][3]f32{{0, 0, 0}, {0, 0, 10}, {10, 0, 10}, {10, 0, 0}}
  normal := calc_poly_normal(square)
  expected := [3]f32{0, 1, 0}
  if !vec3_approx_equal(normal, expected) {
    fmt.printf("Square normal: got %v, expected %v\n", normal, expected)
  }
  testing.expect(
    t,
    vec3_approx_equal(normal, expected),
    "Normal of XZ square should point up",
  )
  // Test triangle
  triangle := [][3]f32{{0, 0, 0}, {1, 0, 0}, {0, 1, 0}}
  normal2 := calc_poly_normal(triangle)
  expected2 := [3]f32{0, 0, 1}
  if !vec3_approx_equal(normal2, expected2) {
    fmt.printf("Triangle normal: got %v, expected %v\n", normal2, expected2)
  }
  testing.expect(
    t,
    vec3_approx_equal(normal2, expected2),
    "Normal should point in Z direction",
  )
}

@(test)
test_poly_area_2d :: proc(t: ^testing.T) {
  // Test square
  square := [][3]f32{{0, 0, 0}, {10, 0, 0}, {10, 0, 10}, {0, 0, 10}}
  area := poly_area_2d(square)
  testing.expect(t, approx_equal(area, 100.0), "Square area should be 100")
  // Test triangle
  triangle := [][3]f32{{0, 0, 0}, {10, 0, 0}, {0, 0, 10}}
  area2 := poly_area_2d(triangle)
  testing.expect(t, approx_equal(area2, 50.0), "Triangle area should be 50")
  // Test clockwise winding (negative area)
  square_cw := [][3]f32{{0, 0, 0}, {0, 0, 10}, {10, 0, 10}, {10, 0, 0}}
  area3 := poly_area_2d(square_cw)
  testing.expect(
    t,
    approx_equal(area3, -100.0),
    "Clockwise square area should be -100",
  )
}

@(test)
test_intersect_segments_2d :: proc(t: ^testing.T) {
  // Test intersecting segments
  ap1 := [3]f32{0, 0, 0}
  aq1 := [3]f32{10, 0, 10}
  bp1 := [3]f32{0, 0, 10}
  bq1 := [3]f32{10, 0, 0}
  hit1, s1, t1 := intersect_segments_2d(ap1, aq1, bp1, bq1)
  testing.expect(t, hit1, "Segments should intersect")
  testing.expect(t, approx_equal(s1, 0.5), "Intersection at s=0.5")
  testing.expect(t, approx_equal(t1, 0.5), "Intersection at t=0.5")
  // Test parallel segments
  ap2 := [3]f32{0, 0, 0}
  aq2 := [3]f32{10, 0, 0}
  bp2 := [3]f32{0, 0, 5}
  bq2 := [3]f32{10, 0, 5}
  hit2, _, _ := intersect_segments_2d(ap2, aq2, bp2, bq2)
  testing.expect(t, !hit2, "Parallel segments should not intersect")
  // Test non-intersecting segments
  ap3 := [3]f32{0, 0, 0}
  aq3 := [3]f32{5, 0, 0}
  bp3 := [3]f32{10, 0, 0}
  bq3 := [3]f32{15, 0, 0}
  hit3, _, _ := intersect_segments_2d(ap3, aq3, bp3, bq3)
  testing.expect(t, !hit3, "Non-overlapping segments should not intersect")
}

@(test)
test_barycentric_2d :: proc(t: ^testing.T) {
  // Test barycentric coordinates for triangle vertices
  a := [3]f32{0, 0, 0}
  b := [3]f32{10, 0, 0}
  c := [3]f32{0, 0, 10}
  // Point at vertex A should have coordinates (1, 0, 0)
  bary_a := barycentric_2d(a, a, b, c)
  testing.expect(t, approx_equal(bary_a.x, 1.0), "Point A should have u=1")
  testing.expect(t, approx_equal(bary_a.y, 0.0), "Point A should have v=0")
  testing.expect(t, approx_equal(bary_a.z, 0.0), "Point A should have w=0")
  // Point at vertex B should have coordinates (0, 1, 0)
  bary_b := barycentric_2d(b, a, b, c)
  testing.expect(t, approx_equal(bary_b.x, 0.0), "Point B should have u=0")
  testing.expect(t, approx_equal(bary_b.y, 1.0), "Point B should have v=1")
  testing.expect(t, approx_equal(bary_b.z, 0.0), "Point B should have w=0")
  // Point at vertex C should have coordinates (0, 0, 1)
  bary_c := barycentric_2d(c, a, b, c)
  testing.expect(t, approx_equal(bary_c.x, 0.0), "Point C should have u=0")
  testing.expect(t, approx_equal(bary_c.y, 0.0), "Point C should have v=0")
  testing.expect(t, approx_equal(bary_c.z, 1.0), "Point C should have w=1")
  // Point at triangle center should have coordinates (1/3, 1/3, 1/3)
  center := [3]f32{10.0 / 3.0, 0, 10.0 / 3.0}
  bary_center := barycentric_2d(center, a, b, c)
  testing.expect(
    t,
    approx_equal(bary_center.x, 1.0 / 3.0),
    "Center should have u≈1/3",
  )
  testing.expect(
    t,
    approx_equal(bary_center.y, 1.0 / 3.0),
    "Center should have v≈1/3",
  )
  testing.expect(
    t,
    approx_equal(bary_center.z, 1.0 / 3.0),
    "Center should have w≈1/3",
  )
  // Test degenerate triangle (collinear points)
  d := [3]f32{0, 0, 0}
  e := [3]f32{5, 0, 0}
  f := [3]f32{10, 0, 0}
  p := [3]f32{3, 0, 0}
  bary_degen := barycentric_2d(p, d, e, f)
  // Should return fallback coordinates (1/3, 1/3, 1/3)
  testing.expect(
    t,
    approx_equal(bary_degen.x, 1.0 / 3.0),
    "Degenerate triangle should return fallback u",
  )
  testing.expect(
    t,
    approx_equal(bary_degen.y, 1.0 / 3.0),
    "Degenerate triangle should return fallback v",
  )
  testing.expect(
    t,
    approx_equal(bary_degen.z, 1.0 / 3.0),
    "Degenerate triangle should return fallback w",
  )
}

@(test)
test_closest_point_on_segment_2d :: proc(t: ^testing.T) {
  // Test point on segment
  p1 := [3]f32{5, 2, 0}
  a := [3]f32{0, 2, 0}
  b := [3]f32{10, 2, 0}
  closest1 := closest_point_on_segment_2d(p1, a, b)
  testing.expect(
    t,
    vec3_approx_equal(closest1, p1),
    "Point on segment should project to itself",
  )
  // Test point perpendicular to segment middle
  p2 := [3]f32{5, 5, 5}
  closest2 := closest_point_on_segment_2d(p2, a, b)
  expected2 := [3]f32{5, 2, 0}
  testing.expect(
    t,
    vec3_approx_equal(closest2, expected2),
    "Point should project to segment middle",
  )
  // Test point beyond segment start
  p3 := [3]f32{-5, 2, 0}
  closest3 := closest_point_on_segment_2d(p3, a, b)
  testing.expect(
    t,
    vec3_approx_equal(closest3, a),
    "Point beyond start should project to start",
  )
  // Test point beyond segment end
  p4 := [3]f32{15, 2, 0}
  closest4 := closest_point_on_segment_2d(p4, a, b)
  testing.expect(
    t,
    vec3_approx_equal(closest4, b),
    "Point beyond end should project to end",
  )
  // Test degenerate segment (point)
  p5 := [3]f32{3, 4, 5}
  closest5 := closest_point_on_segment_2d(p5, a, a)
  testing.expect(
    t,
    vec3_approx_equal(closest5, a),
    "Degenerate segment should return the point",
  )
  // Test with Y interpolation
  a_y := [3]f32{0, 0, 0}
  b_y := [3]f32{10, 10, 0}
  p_y := [3]f32{5, 0, 5}
  closest_y := closest_point_on_segment_2d(p_y, a_y, b_y)
  expected_y := [3]f32{5, 5, 0} // Y should be interpolated
  testing.expect(
    t,
    vec3_approx_equal(closest_y, expected_y),
    "Y coordinate should be interpolated",
  )
}

@(test)
test_calc_tri_normal :: proc(t: ^testing.T) {
  // Test triangle in XY plane (normal should point in +Z direction)
  v0 := [3]f32{0, 0, 0}
  v1 := [3]f32{1, 0, 0}
  v2 := [3]f32{0, 1, 0}
  normal1 := calc_tri_normal(v0, v1, v2)
  expected1 := [3]f32{0, 0, 1}
  testing.expect(
    t,
    vec3_approx_equal(normal1, expected1),
    "XY triangle normal should point +Z",
  )
  // Test triangle in XZ plane (normal should point in -Y direction due to winding)
  v3 := [3]f32{0, 0, 0}
  v4 := [3]f32{1, 0, 0}
  v5 := [3]f32{0, 0, 1}
  normal2 := calc_tri_normal(v3, v4, v5)
  expected2 := [3]f32{0, -1, 0} // Right-hand rule: (1,0,0) × (0,0,1) = (0,-1,0)
  testing.expect(
    t,
    vec3_approx_equal(normal2, expected2),
    "XZ triangle normal should point -Y",
  )
  // Test triangle in YZ plane (normal should point in +X direction)
  v6 := [3]f32{0, 0, 0}
  v7 := [3]f32{0, 1, 0}
  v8 := [3]f32{0, 0, 1}
  normal3 := calc_tri_normal(v6, v7, v8)
  expected3 := [3]f32{1, 0, 0}
  testing.expect(
    t,
    vec3_approx_equal(normal3, expected3),
    "YZ triangle normal should point +X",
  )
  // Test winding order (reversed triangle should have opposite normal)
  normal4 := calc_tri_normal(v0, v2, v1) // Reversed v1 and v2
  expected4 := -linalg.VECTOR3F32_Z_AXIS
  testing.expect(
    t,
    vec3_approx_equal(normal4, expected4),
    "Reversed triangle normal should point -Z",
  )
  // Test arbitrary non-degenerate triangle
  v9 := [3]f32{0, 0, 0}
  v10 := [3]f32{2, 0, 0}
  v11 := [3]f32{1, 2, 0}
  normal5 := calc_tri_normal(v9, v10, v11)
  // This should be a normalized vector, so check length ≈ 1
  length := math.sqrt(
    normal5.x * normal5.x + normal5.y * normal5.y + normal5.z * normal5.z,
  )
  testing.expect(
    t,
    approx_equal(length, 1.0),
    "Triangle normal should be normalized",
  )
  // Test degenerate triangle (collinear points) - normalize may produce NaN
  v12 := [3]f32{0, 0, 0}
  v13 := [3]f32{1, 1, 1}
  v14 := [3]f32{2, 2, 2} // All collinear
  // Degenerate triangle cross product is zero, normalize(zero) may be undefined
  // Just check it doesn't crash - the result may be NaN
  calc_tri_normal(v12, v13, v14)
}

@(test)
test_clamp_usage :: proc(t: ^testing.T) {
  // Test that clamp works correctly in our closest_point_on_segment_2d function
  // This tests the integration rather than the clamp function itself
  p := [3]f32{5, 0, 0}
  a := [3]f32{0, 0, 0}
  b := [3]f32{10, 0, 0}
  // Point that would give t > 1 without clamping
  p_beyond := [3]f32{15, 0, 0}
  closest_beyond := closest_point_on_segment_2d(p_beyond, a, b)
  testing.expect(
    t,
    vec3_approx_equal(closest_beyond, b),
    "Point beyond segment should clamp to endpoint",
  )
  // Point that would give t < 0 without clamping
  p_before := [3]f32{-5, 0, 0}
  closest_before := closest_point_on_segment_2d(p_before, a, b)
  testing.expect(
    t,
    vec3_approx_equal(closest_before, a),
    "Point before segment should clamp to endpoint",
  )
}
