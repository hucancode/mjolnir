package tests

import geometry "../mjolnir/geometry"
import "core:testing"
import "core:math"
import "core:fmt"

// Test constants
EPSILON :: 1e-6

// Helper to compare floats with epsilon
approx_equal :: proc(a, b: f32, epsilon: f32 = EPSILON) -> bool {
    return math.abs(a - b) < epsilon
}

// Helper to compare vectors with epsilon
vec3_approx_equal :: proc(a, b: [3]f32, epsilon: f32 = EPSILON) -> bool {
    return approx_equal(a.x, b.x, epsilon) &&
           approx_equal(a.y, b.y, epsilon) &&
           approx_equal(a.z, b.z, epsilon)
}

@(test)
test_vec2f_perp :: proc(t: ^testing.T) {
    // Test perpendicular vectors: a=(0,0), b=(1,0), c=(0,1) -> cross product = 1
    result := geometry.vec2f_perp({0,0,0}, {1,0, 0}, {0, 0, 1})
    testing.expect_value(t, result, f32(1))

    // Test parallel vectors: a=(0,0), b=(1,0), c=(1,0) -> cross product = 0
    result = geometry.vec2f_perp({0, 0, 0}, {1, 0, 0}, {1, 0, 0})
    testing.expect_value(t, result, f32(0))

    // Test arbitrary vectors: a=(0,0), b=(3,4), c=(1,2) -> (3-0)*(2-0) - (4-0)*(1-0) = 6-4 = 2
    result = geometry.vec2f_perp({0, 0, 0}, {3, 0, 4}, {1, 0, 2})
    testing.expect_value(t, result, f32(2))
}

@(test)
test_next_prev_dir :: proc(t: ^testing.T) {
    // Test next_dir wrapping
    testing.expect_value(t, geometry.next_dir(0), 1)
    testing.expect_value(t, geometry.next_dir(1), 2)
    testing.expect_value(t, geometry.next_dir(2), 3)
    testing.expect_value(t, geometry.next_dir(3), 0)

    // Test prev_dir wrapping
    testing.expect_value(t, geometry.prev_dir(0), 3)
    testing.expect_value(t, geometry.prev_dir(1), 0)
    testing.expect_value(t, geometry.prev_dir(2), 1)
    testing.expect_value(t, geometry.prev_dir(3), 2)
}

@(test)
test_quantize_float :: proc(t: ^testing.T) {
    v := [3]f32{1.2, 3.7, 5.1}
    result := geometry.quantize_float(v, 10.0)

    testing.expect_value(t, result[0], i32(12))
    testing.expect_value(t, result[1], i32(37))
    testing.expect_value(t, result[2], i32(51))

    // Test with negative values
    v2 := [3]f32{-1.2, -3.7, -5.1}
    result2 := geometry.quantize_float(v2, 10.0)

    testing.expect_value(t, result2[0], i32(-12))
    testing.expect_value(t, result2[1], i32(-37))
    testing.expect_value(t, result2[2], i32(-51))
}

@(test)
test_overlap_bounds :: proc(t: ^testing.T) {
    // Test overlapping bounds
    amin1 := [3]f32{0, 0, 0}
    amax1 := [3]f32{10, 10, 10}
    bmin1 := [3]f32{5, 5, 5}
    bmax1 := [3]f32{15, 15, 15}

    testing.expect(t, geometry.overlap_bounds(amin1, amax1, bmin1, bmax1), "Bounds should overlap")

    // Test non-overlapping bounds
    bmin2 := [3]f32{15, 15, 15}
    bmax2 := [3]f32{20, 20, 20}

    testing.expect(t, !geometry.overlap_bounds(amin1, amax1, bmin2, bmax2), "Bounds should not overlap")

    // Test touching bounds (edge case)
    bmin3 := [3]f32{10, 10, 10}
    bmax3 := [3]f32{20, 20, 20}

    testing.expect(t, geometry.overlap_bounds(amin1, amax1, bmin3, bmax3), "Touching bounds should overlap")
}

@(test)
test_overlap_quantized_bounds :: proc(t: ^testing.T) {
    // Test overlapping quantized bounds
    amin1 := [3]i32{0, 0, 0}
    amax1 := [3]i32{10, 10, 10}
    bmin1 := [3]i32{5, 5, 5}
    bmax1 := [3]i32{15, 15, 15}

    testing.expect(t, geometry.overlap_quantized_bounds(amin1, amax1, bmin1, bmax1), "Quantized bounds should overlap")

    // Test non-overlapping quantized bounds
    bmin2 := [3]i32{15, 15, 15}
    bmax2 := [3]i32{20, 20, 20}

    testing.expect(t, !geometry.overlap_quantized_bounds(amin1, amax1, bmin2, bmax2), "Quantized bounds should not overlap")
}

@(test)
test_triangle_area_2d :: proc(t: ^testing.T) {
    // Test right triangle
    a := [3]f32{0, 0, 0}
    b := [3]f32{3, 0, 0}
    c := [3]f32{0, 0, 4}

    area := geometry.triangle_area_2d(a, b, c)
    testing.expect(t, approx_equal(area, 6.0), "Triangle area should be 6")
    area = geometry.triangle_area_2d(a, c, b)
    testing.expect(t, approx_equal(area, 6.0), "Triangle area should be 6")

    // Test degenerate triangle (collinear points)
    d := [3]f32{0, 0, 0}
    e := [3]f32{1, 0, 0}
    f := [3]f32{2, 0, 0}

    area2 := geometry.triangle_area_2d(d, e, f)
    testing.expect(t, approx_equal(area2, 0.0), "Degenerate triangle area should be 0")
}

@(test)
test_point_in_polygon_2d :: proc(t: ^testing.T) {
    // Test square polygon
    square := [][3]f32{
        {0, 0, 0},
        {10, 0, 0},
        {10, 0, 10},
        {0, 0, 10},
    }

    // Test point inside
    pt_inside := [3]f32{5, 0, 5}
    testing.expect(t, geometry.point_in_polygon_2d(pt_inside, square), "Point should be inside square")

    // Test point outside
    pt_outside := [3]f32{15, 0, 15}
    testing.expect(t, !geometry.point_in_polygon_2d(pt_outside, square), "Point should be outside square")

    // Test point on edge
    pt_edge := [3]f32{5, 0, 0}
    edge_result := geometry.point_in_polygon_2d(pt_edge, square)
    if edge_result {
        fmt.printf("Point on edge returned %v, expected false\n", edge_result)
    }
    testing.expect(t, !edge_result, "Point on edge should be considered outside")

    // Test point on vertex
    pt_vertex := [3]f32{0, 0, 0}
    testing.expect(t, !geometry.point_in_polygon_2d(pt_vertex, square), "Point on vertex should be considered outside")

    // Test concave polygon
    // Drawing in XZ plane:
    // (0,10)---(5,5)---(10,10)
    //   |       /          |
    //   |      /           |
    //   |     /            |
    // (0,0)-------------(10,0)
    concave := [][3]f32{
        {0, 0, 0},
        {10, 0, 0},
        {10, 0, 10},
        {5, 0, 5},  // Concave point - creates notch
        {0, 0, 10},
    }

    // Point at (2, 4.5) is clearly inside the polygon (avoiding edge case at z=5)
    pt_concave_in := [3]f32{2, 0, 4.5}
    in_result := geometry.point_in_polygon_2d(pt_concave_in, concave)
    if !in_result {
        fmt.printf("Point (2,0,4.5) returned %v, expected true\n", in_result)
    }
    testing.expect(t, in_result, "Point should be inside concave polygon")

    // Test a point that's clearly outside
    // Point (15, 5) is outside the polygon entirely
    pt_concave_out := [3]f32{15, 0, 5}
    out_result := geometry.point_in_polygon_2d(pt_concave_out, concave)
    if out_result {
        fmt.printf("Point (15,0,5) returned %v, expected false\n", out_result)
    }
    testing.expect(t, !out_result, "Point at (15,5) should be outside concave polygon")
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

    hit1, t1 := geometry.intersect_segment_triangle(sp1, sq1, a, b, c)
    testing.expect(t, hit1, "Segment should intersect triangle")
    testing.expect(t, approx_equal(t1, 0.5), "Intersection should be at t=0.5")

    // Test segment that misses triangle
    sp2 := [3]f32{20, 5, 20}
    sq2 := [3]f32{20, -5, 20}

    hit2, _ := geometry.intersect_segment_triangle(sp2, sq2, a, b, c)
    testing.expect(t, !hit2, "Segment should miss triangle")

    // Test segment parallel to triangle
    sp3 := [3]f32{2, 0, 2}
    sq3 := [3]f32{5, 0, 5}

    hit3, _ := geometry.intersect_segment_triangle(sp3, sq3, a, b, c)
    testing.expect(t, !hit3, "Parallel segment should not intersect")

    // Test segment that starts inside and goes out
    sp4 := [3]f32{2, -1, 2}
    sq4 := [3]f32{2, 1, 2}

    hit4, t4 := geometry.intersect_segment_triangle(sp4, sq4, a, b, c)
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
    closest1 := geometry.closest_point_on_triangle(p1, a, b, c)
    testing.expect(t, vec3_approx_equal(closest1, a), "Closest point should be vertex A")

    // Test point closest to vertex B
    p2 := [3]f32{15, 5, -5}
    closest2 := geometry.closest_point_on_triangle(p2, a, b, c)
    testing.expect(t, vec3_approx_equal(closest2, b), "Closest point should be vertex B")

    // Test point closest to vertex C
    p3 := [3]f32{-5, 5, 15}
    closest3 := geometry.closest_point_on_triangle(p3, a, b, c)
    testing.expect(t, vec3_approx_equal(closest3, c), "Closest point should be vertex C")

    // Test point closest to edge AB
    p4 := [3]f32{5, 5, -5}
    closest4 := geometry.closest_point_on_triangle(p4, a, b, c)
    expected4 := [3]f32{5, 0, 0}
    testing.expect(t, vec3_approx_equal(closest4, expected4), "Closest point should be on edge AB")

    // Test point inside triangle (projects to itself)
    p5 := [3]f32{2, 0, 2}
    closest5 := geometry.closest_point_on_triangle(p5, a, b, c)
    testing.expect(t, vec3_approx_equal(closest5, p5), "Point inside triangle should project to itself")
}

@(test)
test_dist_point_segment_sq_2d :: proc(t: ^testing.T) {
    // Test point on segment
    pt1 := [3]f32{5, 0, 0}
    p := [3]f32{0, 0, 0}
    q := [3]f32{10, 0, 0}

    dist1 := geometry.dist_point_segment_sq_2d(pt1, p, q)
    testing.expect(t, approx_equal(dist1, 0.0), "Distance to point on segment should be 0")

    // Test point perpendicular to segment
    pt2 := [3]f32{5, 0, 5}
    dist2 := geometry.dist_point_segment_sq_2d(pt2, p, q)
    testing.expect(t, approx_equal(dist2, 25.0), "Squared distance should be 25")

    // Test point beyond segment end
    pt3 := [3]f32{15, 0, 0}
    dist3 := geometry.dist_point_segment_sq_2d(pt3, p, q)
    testing.expect(t, approx_equal(dist3, 25.0), "Squared distance to segment end should be 25")

    // Test degenerate segment (point)
    pt4 := [3]f32{3, 0, 4}
    dist4 := geometry.dist_point_segment_sq_2d(pt4, p, p)
    testing.expect(t, approx_equal(dist4, 25.0), "Squared distance to degenerate segment should be 25")
}

@(test)
test_dist_point_segment_sq :: proc(t: ^testing.T) {
    // Test 3D point-segment distance
    pt1 := [3]f32{5, 5, 0}
    p := [3]f32{0, 0, 0}
    q := [3]f32{10, 0, 0}

    dist1 := geometry.dist_point_segment_sq_2d(pt1, p, q)
    testing.expect(t, approx_equal(dist1, 25.0), "3D squared distance should be 25")

    // Test point with Y component
    pt2 := [3]f32{5, 3, 4}
    dist2 := geometry.dist_point_segment_sq_2d(pt2, p, q)
    testing.expect(t, approx_equal(dist2, 25.0), "3D squared distance should be 25")
}

@(test)
test_calc_poly_normal :: proc(t: ^testing.T) {
    // Test square in XZ plane
    // Use counter-clockwise winding when viewed from above for upward normal
    square := [][3]f32{
        {0, 0, 0},
        {0, 0, 10},
        {10, 0, 10},
        {10, 0, 0},
    }

    normal := geometry.calc_poly_normal(square)
    expected := [3]f32{0, 1, 0}
    if !vec3_approx_equal(normal, expected) {
        fmt.printf("Square normal: got %v, expected %v\n", normal, expected)
    }
    testing.expect(t, vec3_approx_equal(normal, expected), "Normal of XZ square should point up")

    // Test triangle
    triangle := [][3]f32{
        {0, 0, 0},
        {1, 0, 0},
        {0, 1, 0},
    }

    normal2 := geometry.calc_poly_normal(triangle)
    expected2 := [3]f32{0, 0, 1}
    if !vec3_approx_equal(normal2, expected2) {
        fmt.printf("Triangle normal: got %v, expected %v\n", normal2, expected2)
    }
    testing.expect(t, vec3_approx_equal(normal2, expected2), "Normal should point in Z direction")
}

@(test)
test_poly_area_2d :: proc(t: ^testing.T) {
    // Test square
    square := [][3]f32{
        {0, 0, 0},
        {10, 0, 0},
        {10, 0, 10},
        {0, 0, 10},
    }

    area := geometry.poly_area_2d(square)
    testing.expect(t, approx_equal(area, 100.0), "Square area should be 100")

    // Test triangle
    triangle := [][3]f32{
        {0, 0, 0},
        {10, 0, 0},
        {0, 0, 10},
    }

    area2 := geometry.poly_area_2d(triangle)
    testing.expect(t, approx_equal(area2, 50.0), "Triangle area should be 50")

    // Test clockwise winding (negative area)
    square_cw := [][3]f32{
        {0, 0, 0},
        {0, 0, 10},
        {10, 0, 10},
        {10, 0, 0},
    }

    area3 := geometry.poly_area_2d(square_cw)
    testing.expect(t, approx_equal(area3, -100.0), "Clockwise square area should be -100")
}

@(test)
test_intersect_segments_2d :: proc(t: ^testing.T) {
    // Test intersecting segments
    ap1 := [3]f32{0, 0, 0}
    aq1 := [3]f32{10, 0, 10}
    bp1 := [3]f32{0, 0, 10}
    bq1 := [3]f32{10, 0, 0}

    hit1, s1, t1 := geometry.intersect_segments_2d(ap1, aq1, bp1, bq1)
    testing.expect(t, hit1, "Segments should intersect")
    testing.expect(t, approx_equal(s1, 0.5), "Intersection at s=0.5")
    testing.expect(t, approx_equal(t1, 0.5), "Intersection at t=0.5")

    // Test parallel segments
    ap2 := [3]f32{0, 0, 0}
    aq2 := [3]f32{10, 0, 0}
    bp2 := [3]f32{0, 0, 5}
    bq2 := [3]f32{10, 0, 5}

    hit2, _, _ := geometry.intersect_segments_2d(ap2, aq2, bp2, bq2)
    testing.expect(t, !hit2, "Parallel segments should not intersect")

    // Test non-intersecting segments
    ap3 := [3]f32{0, 0, 0}
    aq3 := [3]f32{5, 0, 0}
    bp3 := [3]f32{10, 0, 0}
    bq3 := [3]f32{15, 0, 0}

    hit3, _, _ := geometry.intersect_segments_2d(ap3, aq3, bp3, bq3)
    testing.expect(t, !hit3, "Non-overlapping segments should not intersect")
}

@(test)
test_overlap_circle_segment :: proc(t: ^testing.T) {
    center := [3]f32{5, 0, 5}
    radius := f32(3)

    // Test segment that passes through circle
    p1 := [3]f32{0, 0, 5}
    q1 := [3]f32{10, 0, 5}

    testing.expect(t, geometry.overlap_circle_segment(center, radius, p1, q1), "Segment should overlap circle")

    // Test segment outside circle
    p2 := [3]f32{0, 0, 10}
    q2 := [3]f32{10, 0, 10}

    testing.expect(t, !geometry.overlap_circle_segment(center, radius, p2, q2), "Segment should not overlap circle")

    // Test segment tangent to circle
    p3 := [3]f32{0, 0, 8}
    q3 := [3]f32{10, 0, 8}

    testing.expect(t, geometry.overlap_circle_segment(center, radius, p3, q3), "Tangent segment should overlap circle")
}

@(test)
test_next_pow2 :: proc(t: ^testing.T) {
    testing.expect_value(t, geometry.next_pow2(0), u32(0))
    testing.expect_value(t, geometry.next_pow2(1), u32(1))
    testing.expect_value(t, geometry.next_pow2(2), u32(2))
    testing.expect_value(t, geometry.next_pow2(3), u32(4))
    testing.expect_value(t, geometry.next_pow2(5), u32(8))
    testing.expect_value(t, geometry.next_pow2(16), u32(16))
    testing.expect_value(t, geometry.next_pow2(17), u32(32))
    testing.expect_value(t, geometry.next_pow2(1000), u32(1024))
}

@(test)
test_ilog2 :: proc(t: ^testing.T) {
    testing.expect_value(t, geometry.ilog2(1), u32(0))
    testing.expect_value(t, geometry.ilog2(2), u32(1))
    testing.expect_value(t, geometry.ilog2(4), u32(2))
    testing.expect_value(t, geometry.ilog2(8), u32(3))
    testing.expect_value(t, geometry.ilog2(16), u32(4))
    testing.expect_value(t, geometry.ilog2(31), u32(4))
    testing.expect_value(t, geometry.ilog2(32), u32(5))
    testing.expect_value(t, geometry.ilog2(1024), u32(10))
}

@(test)
test_align :: proc(t: ^testing.T) {
    testing.expect_value(t, geometry.align(0, 4), 0)
    testing.expect_value(t, geometry.align(1, 4), 4)
    testing.expect_value(t, geometry.align(3, 4), 4)
    testing.expect_value(t, geometry.align(4, 4), 4)
    testing.expect_value(t, geometry.align(5, 4), 8)
    testing.expect_value(t, geometry.align(15, 8), 16)
    testing.expect_value(t, geometry.align(16, 8), 16)
}
