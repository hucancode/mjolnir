#+build !js
package recast

import "core:testing"

@(test)
test_area2 :: proc(t: ^testing.T) {
  // Test counter-clockwise triangle (positive area)
  a := [2]i32{0, 0}
  b := [2]i32{10, 0}
  c := [2]i32{0, 10}
  area_ccw := area2(a, b, c)
  testing.expect(
    t,
    area_ccw > 0,
    "Counter-clockwise triangle should have positive area",
  )
  testing.expect_value(t, area_ccw, i32(100))
  // Test clockwise triangle (negative area)
  area_cw := area2(a, c, b) // Reversed c and b
  testing.expect(
    t,
    area_cw < 0,
    "Clockwise triangle should have negative area",
  )
  testing.expect_value(t, area_cw, i32(-100))
  // Test collinear points (zero area)
  d := [2]i32{20, 0}
  area_collinear := area2(a, b, d)
  testing.expect_value(t, area_collinear, i32(0))
}

@(test)
test_left_left_on :: proc(t: ^testing.T) {
  // Test with area2 function: (b.x-a.x)*(c.y-a.y) - (c.x-a.x)*(b.y-a.y)
  // For a=(0,0), b=(10,0), c=(5,5): (10-0)*(5-0) - (5-0)*(0-0) = 10*5 - 5*0 = 50 > 0
  // So area2 > 0, left() returns false (since left checks area2 < 0)
  a := [2]i32{0, 0}
  b := [2]i32{10, 0}
  c := [2]i32{5, 5} // Point above line ab
  testing.expect(
    t,
    !left(a, b, c),
    "Point above line should NOT be left (area2 > 0)",
  )
  testing.expect(
    t,
    !left_on(a, b, c),
    "Point above line should NOT be left_on (area2 > 0)",
  )
  // Test right turn - point below line
  // For a=(0,0), b=(10,0), d=(5,-5): (10-0)*(-5-0) - (5-0)*(0-0) = 10*(-5) - 5*0 = -50 < 0
  // So area2 < 0, left() returns true
  d := [2]i32{5, -5} // Point below line ab
  testing.expect(
    t,
    left(a, b, d),
    "Point below line should be left (area2 < 0)",
  )
  testing.expect(
    t,
    left_on(a, b, d),
    "Point below line should be left_on (area2 < 0)",
  )
  // Test collinear point
  // For a=(0,0), b=(10,0), e=(5,0): (10-0)*(0-0) - (5-0)*(0-0) = 10*0 - 5*0 = 0
  // So area2 = 0, left() returns false, left_on() returns true
  e := [2]i32{5, 0} // Point on line ab
  testing.expect(
    t,
    !left(a, b, e),
    "Collinear point should not be left (area2 = 0)",
  )
  testing.expect(
    t,
    left_on(a, b, e),
    "Collinear point should be left_on (area2 = 0)",
  )
}

@(test)
test_between :: proc(t: ^testing.T) {
  // Test point between two points on horizontal line
  a := [2]i32{0, 0}
  b := [2]i32{10, 0}
  c := [2]i32{5, 0}
  testing.expect(
    t,
    between(a, b, c),
    "Point should be between endpoints",
  )
  testing.expect(
    t,
    between(b, a, c),
    "Order shouldn't matter for between",
  )
  // Test point not between (but collinear)
  d := [2]i32{15, 0}
  testing.expect(
    t,
    !between(a, b, d),
    "Point beyond segment should not be between",
  )
  e := [2]i32{-5, 0}
  testing.expect(
    t,
    !between(a, b, e),
    "Point before segment should not be between",
  )
  // Test endpoints
  testing.expect(t, between(a, b, a), "Endpoint should be between")
  testing.expect(t, between(a, b, b), "Endpoint should be between")
  // Test vertical line
  f := [2]i32{0, 0}
  g := [2]i32{0, 10}
  h := [2]i32{0, 5}
  testing.expect(
    t,
    between(f, g, h),
    "Point should be between on vertical line",
  )
  // Test non-collinear point
  i := [2]i32{5, 5}
  testing.expect(
    t,
    !between(a, b, i),
    "Non-collinear point should not be between",
  )
}

@(test)
test_intersect_prop :: proc(t: ^testing.T) {
  // Test proper intersection (X crossing)
  a := [2]i32{0, 0}
  b := [2]i32{10, 10}
  c := [2]i32{0, 10}
  d := [2]i32{10, 0}
  testing.expect(
    t,
    intersect_prop(a, b, c, d),
    "X-crossing segments should intersect properly",
  )
  // Test parallel segments (no intersection)
  e := [2]i32{0, 0}
  f := [2]i32{10, 0}
  g := [2]i32{0, 5}
  h := [2]i32{10, 5}
  testing.expect(
    t,
    !intersect_prop(e, f, g, h),
    "Parallel segments should not intersect",
  )
  // Test segments sharing an endpoint (improper intersection)
  i := [2]i32{0, 0}
  j := [2]i32{10, 0}
  k := [2]i32{0, 0} // Same as i
  l := [2]i32{0, 10}
  testing.expect(
    t,
    !intersect_prop(i, j, k, l),
    "Segments sharing endpoint should not intersect properly",
  )
  // Test T-junction (improper intersection)
  m := [2]i32{0, 0}
  n := [2]i32{10, 0}
  o := [2]i32{5, -5}
  p := [2]i32{5, 0} // Endpoint on segment mn
  testing.expect(
    t,
    !intersect_prop(m, n, o, p),
    "T-junction should not be proper intersection",
  )
}

@(test)
test_intersect :: proc(t: ^testing.T) {
  // Test proper intersection
  a := [2]i32{0, 0}
  b := [2]i32{10, 10}
  c := [2]i32{0, 10}
  d := [2]i32{10, 0}
  testing.expect(
    t,
    intersect(a, b, c, d),
    "X-crossing segments should intersect",
  )
  // Test segments sharing an endpoint (improper but still intersection)
  e := [2]i32{0, 0}
  f := [2]i32{10, 0}
  g := [2]i32{0, 0} // Same as e
  h := [2]i32{0, 10}
  testing.expect(
    t,
    intersect(e, f, g, h),
    "Segments sharing endpoint should intersect",
  )
  // Test T-junction (improper but still intersection)
  i := [2]i32{0, 0}
  j := [2]i32{10, 0}
  k := [2]i32{5, -5}
  l := [2]i32{5, 0} // Endpoint on segment ij
  testing.expect(
    t,
    intersect(i, j, k, l),
    "T-junction should intersect",
  )
  // Test overlapping collinear segments
  m := [2]i32{0, 0}
  n := [2]i32{10, 0}
  o := [2]i32{5, 0}
  p := [2]i32{15, 0}
  testing.expect(
    t,
    intersect(m, n, o, p),
    "Overlapping collinear segments should intersect",
  )
  // Test non-intersecting segments
  q := [2]i32{0, 0}
  r := [2]i32{5, 0}
  s := [2]i32{10, 0}
  u := [2]i32{15, 0}
  testing.expect(
    t,
    !intersect(q, r, s, u),
    "Non-overlapping segments should not intersect",
  )
}

@(test)
test_in_cone :: proc(t: ^testing.T) {
  // The in_cone function is complex and depends on whether the vertex is convex or reflex
  // Let me test with a simpler, more predictable configuration
  // Test simple convex case: right angle cone
  a0 := [2]i32{0, 0} // Previous vertex
  a1 := [2]i32{0, 5} // Apex of cone (current vertex)
  a2 := [2]i32{5, 5} // Next vertex
  // This should create a convex vertex (90 degree angle)
  // Check if a2 is left_on of line a0->a1: area2(a0,a1,a2) = area2((0,0),(0,5),(5,5))
  // = (0-0)*(5-0) - (5-0)*(5-0) = 0*5 - 5*5 = -25 <= 0, so it's convex
  p_inside := [2]i32{2, 3} // Point that should be inside the cone
  testing.expect(
    t,
    in_cone(a0, a1, a2, p_inside),
    "Point should be inside convex cone",
  )
  // Point clearly outside the cone
  p_outside := [2]i32{-2, 3} // Point to the left, outside cone
  testing.expect(
    t,
    !in_cone(a0, a1, a2, p_outside),
    "Point should be outside convex cone",
  )
  // Test reflex vertex cone (vertex angle > 180 degrees)
  // Create a reflex angle by making the turn > 180 degrees
  a0_r := [2]i32{0, 0}
  a1_r := [2]i32{5, 0} // Apex
  a2_r := [2]i32{0, 5} // This creates a reflex angle at a1_r
  // Point that should be inside reflex cone (in the "excluded" region of convex)
  p_reflex_inside := [2]i32{2, -1}
  testing.expect(
    t,
    in_cone(a0_r, a1_r, a2_r, p_reflex_inside),
    "Point should be inside reflex cone",
  )
}
