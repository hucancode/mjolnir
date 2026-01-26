package navigation_recast

import "core:log"
import "core:testing"
import "core:time"

@(test)
test_filter_low_hanging_obstacles_basic :: proc(t: ^testing.T) {
  hf := create_heightfield(5, 5, {0, 0, 0}, {5, 5, 5}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add walkable span at ground level
  add_span(hf, 2, 2, 0, 2, RC_WALKABLE_AREA, 1)
  // testing.expect(t, ok, "Failed to add walkable span")
  // Add non-walkable span just above it (obstacle)
  add_span(hf, 2, 2, 3, 4, RC_NULL_AREA, 1)
  // testing.expect(t, ok, "Failed to add obstacle span")
  // Apply filter with walkable_climb = 2
  filter_low_hanging_walkable_obstacles(2, hf)
  // The obstacle should now be walkable because it's within climb height
  column_index := 2 + 2 * hf.width
  span := hf.spans[column_index]
  // Find the obstacle span (should be second in list)
  obstacle_span := span.next
  testing.expect(t, obstacle_span != nil, "Should have obstacle span")
  if obstacle_span != nil {
    testing.expect(
      t,
      obstacle_span.area == RC_WALKABLE_AREA,
      "Obstacle should be marked walkable after filter",
    )
  }
}

@(test)
test_filter_low_hanging_obstacles_too_high :: proc(t: ^testing.T) {
  hf := create_heightfield(5, 5, {0, 0, 0}, {5, 5, 5}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add walkable span at ground level
  add_span(hf, 2, 2, 0, 2, RC_WALKABLE_AREA, 1)
  // testing.expect(t, ok, "Failed to add walkable span")
  // Add non-walkable span too high above it
  add_span(hf, 2, 2, 5, 7, RC_NULL_AREA, 1)
  // testing.expect(t, ok, "Failed to add high obstacle span")
  // Apply filter with walkable_climb = 2 (span difference is 3, too high)
  filter_low_hanging_walkable_obstacles(2, hf)
  // The obstacle should remain non-walkable
  column_index := 2 + 2 * hf.width
  span := hf.spans[column_index]
  obstacle_span := span.next
  testing.expect(t, obstacle_span != nil, "Should have obstacle span")
  if obstacle_span != nil {
    testing.expect(
      t,
      obstacle_span.area == RC_NULL_AREA,
      "High obstacle should remain non-walkable",
    )
  }
}

@(test)
test_filter_low_hanging_obstacles_multiple_spans :: proc(t: ^testing.T) {
  hf := create_heightfield(5, 5, {0, 0, 0}, {5, 5, 5}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Create complex span column: walkable, obstacle (low), walkable, obstacle (high)
  ok := add_span(hf, 2, 2, 0, 2, RC_WALKABLE_AREA, 1)
  testing.expect(t, ok, "Failed to add ground walkable span")
  ok = add_span(hf, 2, 2, 3, 4, RC_NULL_AREA, 1)
  testing.expect(t, ok, "Failed to add low obstacle")
  ok = add_span(hf, 2, 2, 5, 7, RC_WALKABLE_AREA, 1)
  testing.expect(t, ok, "Failed to add upper walkable span")
  ok = add_span(hf, 2, 2, 10, 12, RC_NULL_AREA, 1)
  testing.expect(t, ok, "Failed to add high obstacle")
  // Apply filter with walkable_climb = 2
  filter_low_hanging_walkable_obstacles(2, hf)
  // Check results: low obstacle should be walkable, high obstacle should not
  column_index := 2 + 2 * hf.width
  span := hf.spans[column_index]
  // Ground span (walkable)
  testing.expect(
    t,
    span.area == RC_WALKABLE_AREA,
    "Ground should be walkable",
  )
  // Low obstacle (should be converted to walkable)
  span = span.next
  testing.expect(
    t,
    span.area == RC_WALKABLE_AREA,
    "Low obstacle should be walkable",
  )
  // Upper walkable (should remain walkable)
  span = span.next
  testing.expect(
    t,
    span.area == RC_WALKABLE_AREA,
    "Upper walkable should remain walkable",
  )
  // High obstacle (should remain non-walkable because gap from upper walkable is too big)
  span = span.next
  testing.expect(
    t,
    span.area == RC_NULL_AREA,
    "High obstacle should remain non-walkable",
  )
}

@(test)
test_filter_ledge_spans_basic :: proc(t: ^testing.T) {
  // Create heightfield and compact heightfield for ledge filtering
  hf := create_heightfield(5, 5, {0, 0, 0}, {5, 5, 5}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Create a ledge scenario: walkable area with drop-off
  // Add walkable spans in center and some neighbors, but not all
  ok := add_span(hf, 2, 2, 0, 2, RC_WALKABLE_AREA, 1) // Center
  testing.expect(t, ok, "Failed to add center span")
  ok = add_span(hf, 1, 2, 0, 2, RC_WALKABLE_AREA, 1) // Left neighbor
  testing.expect(t, ok, "Failed to add left neighbor")
  ok = add_span(hf, 2, 1, 0, 2, RC_WALKABLE_AREA, 1) // Bottom neighbor
  testing.expect(t, ok, "Failed to add bottom neighbor")
  // Missing right (3,2) and top (2,3) neighbors - this creates a ledge
  // Build compact heightfield
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  testing.expect(t, chf != nil, "Failed to build compact heightfield")
  // Apply ledge filter with walkable_height = 4 (must be able to stand)
  filter_ledge_spans(4, 2, hf)
  // Check if spans near ledges are filtered out
  // Center span should be filtered because it has missing neighbors (ledge)
  center_idx := 2 + 2 * hf.width
  span := hf.spans[center_idx]
  if span != nil {
    // Area should be set to RC_NULL_AREA if it's a dangerous ledge
    log.infof("Center span area after ledge filter: %d", span.area)
  }
}

@(test)
test_filter_ledge_spans_safe_area :: proc(t: ^testing.T) {
  hf := create_heightfield(5, 5, {0, 0, 0}, {5, 5, 5}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Create a safe area with all neighbors present
  for x in 1 ..= 3 {
    for z in 1 ..= 3 {
      add_span(hf, i32(x), i32(z), 0, 2, RC_WALKABLE_AREA, 1)
      // testing.expect(t, ok, "Failed to add safe area span")
    }
  }
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  testing.expect(t, chf != nil, "Failed to build compact heightfield")
  // Apply ledge filter
  filter_ledge_spans(4, 2, hf)
  // All spans in the safe area should remain walkable
  center_idx := 2 + 2 * hf.width
  span := hf.spans[center_idx]
  testing.expect(t, span != nil, "Should have spans in safe area")
  if span != nil {
    testing.expect(
      t,
      span.area == RC_WALKABLE_AREA,
      "Safe area should remain walkable",
    )
  }
}

@(test)
test_filter_walkable_low_height_spans_basic :: proc(t: ^testing.T) {
  hf := create_heightfield(5, 5, {0, 0, 0}, {5, 5, 5}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add walkable span with low ceiling (insufficient height clearance)
  add_span(hf, 2, 2, 0, 2, RC_WALKABLE_AREA, 1)
  // testing.expect(t, ok, "Failed to add ground span")
  // Add ceiling span very close above (height = 2 units)
  add_span(hf, 2, 2, 4, 6, RC_NULL_AREA, 1)
  // testing.expect(t, ok, "Failed to add ceiling span")
  // Apply filter with walkable_height = 4 (requires 4 units clearance)
  filter_walkable_low_height_spans(4, hf)
  // Ground span should be filtered out due to insufficient clearance
  column_index := 2 + 2 * hf.width
  span := hf.spans[column_index]
  testing.expect(t, span != nil, "Should have span")
  if span != nil {
    // The span should be marked as non-walkable
    testing.expect(
      t,
      span.area == RC_NULL_AREA,
      "Span with low clearance should be filtered",
    )
  }
}

@(test)
test_filter_walkable_low_height_spans_sufficient_height :: proc(
  t: ^testing.T,
) {
  hf := create_heightfield(5, 5, {0, 0, 0}, {5, 5, 5}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add walkable span with sufficient ceiling height
  add_span(hf, 2, 2, 0, 2, RC_WALKABLE_AREA, 1)
  // testing.expect(t, ok, "Failed to add ground span")
  // Add ceiling span with sufficient clearance (6 units above ground span max)
  add_span(hf, 2, 2, 8, 10, RC_NULL_AREA, 1)
  // testing.expect(t, ok, "Failed to add ceiling span")
  // Apply filter with walkable_height = 4
  filter_walkable_low_height_spans(4, hf)
  // Ground span should remain walkable
  column_index := 2 + 2 * hf.width
  span := hf.spans[column_index]
  testing.expect(t, span != nil, "Should have span")
  if span != nil {
    testing.expect(
      t,
      span.area == RC_WALKABLE_AREA,
      "Span with sufficient clearance should remain walkable",
    )
  }
}

@(test)
test_filter_walkable_low_height_no_ceiling :: proc(t: ^testing.T) {
  hf := create_heightfield(5, 5, {0, 0, 0}, {5, 5, 5}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add walkable span with no ceiling (open sky)
  add_span(hf, 2, 2, 0, 2, RC_WALKABLE_AREA, 1)
  // testing.expect(t, ok, "Failed to add ground span")
  // Apply filter with walkable_height = 4
  filter_walkable_low_height_spans(4, hf)
  // Ground span should remain walkable (no ceiling constraint)
  column_index := 2 + 2 * hf.width
  span := hf.spans[column_index]
  testing.expect(t, span != nil, "Should have span")
  if span != nil {
    testing.expect(
      t,
      span.area == RC_WALKABLE_AREA,
      "Span with no ceiling should remain walkable",
    )
  }
}

@(test)
test_filter_interactions_combined :: proc(t: ^testing.T) {
  // Test applying multiple filters in sequence to ensure they work together
  hf := create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Create complex scenario with multiple filter conditions
  // Ground level walkable area
  for x in 2 ..= 7 {
    for z in 2 ..= 7 {
      add_span(hf, i32(x), i32(z), 0, 2, RC_WALKABLE_AREA, 1)
      // testing.expect(t, ok, "Failed to add ground span")
    }
  }
  // Add some low hanging obstacles
  add_span(hf, 4, 4, 3, 4, RC_NULL_AREA, 1) // Low obstacle
  // testing.expect(t, ok, "Failed to add low obstacle")
  // Add low ceiling in one area
  add_span(hf, 6, 6, 3, 5, RC_NULL_AREA, 1) // Low ceiling
  // testing.expect(t, ok, "Failed to add low ceiling")
  // Apply filters in sequence
  filter_low_hanging_walkable_obstacles(2, hf)
  filter_walkable_low_height_spans(4, hf)
  // Build compact heightfield for ledge filtering
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  testing.expect(t, chf != nil, "Failed to build compact heightfield")
  filter_ledge_spans(4, 2, hf)
  // Verify that combined filters worked correctly
  // Check that we have reasonable walkable area left after filtering
  walkable_count := 0
  total_spans := 0
  for i in 0 ..< (hf.width * hf.height) {
    if span := hf.spans[i]; span != nil {
      s := span
      for s != nil {
        total_spans += 1
        if s.area == RC_WALKABLE_AREA {
          walkable_count += 1
        }
        s = s.next
      }
    }
  }
  // Basic validation - filters should not remove all walkable area
  testing.expect(
    t,
    walkable_count > 0,
    "Should have walkable area after filtering",
  )
  testing.expect(t, total_spans > 0, "Should have spans after filtering")
  // The filters should have processed the heightfield without crashing
  // We originally had a 6x6=36 ground spans, but filters may modify/remove some
  testing.expectf(
    t,
    walkable_count <= 36,
    "Should not exceed original ground spans, walkable spans %d/%d",
    walkable_count,
    total_spans,
  )
}

@(test)
test_all_filters :: proc(t: ^testing.T) {
  // Test 1: Low hanging obstacle (smax-smax check)
  {
    hf := Heightfield {
      width  = 1,
      height = 1,
      spans  = make([]^Span, 1),
    }
    defer delete(hf.spans)
    floor := new(Span)
    floor.smax = 10
    floor.area = RC_WALKABLE_AREA
    obstacle := new(Span)
    obstacle.smin = 12
    obstacle.smax = 15
    obstacle.area = RC_NULL_AREA
    floor.next = obstacle
    hf.spans[0] = floor
    filter_low_hanging_walkable_obstacles(5, &hf)
    testing.expect(
      t,
      obstacle.area != RC_NULL_AREA,
      "climb=5 should be walkable",
    )
    obstacle.area = RC_NULL_AREA
    filter_low_hanging_walkable_obstacles(4, &hf)
    testing.expect(
      t,
      obstacle.area == RC_NULL_AREA,
      "climb=5 exceeds limit=4",
    )
    free(floor)
    free(obstacle)
  }
  // Test 2: Low height clearance
  {
    hf := Heightfield {
      width  = 1,
      height = 1,
      spans  = make([]^Span, 1),
    }
    defer delete(hf.spans)
    floor := new(Span)
    floor.smax = 10
    floor.area = RC_WALKABLE_AREA
    ceiling := new(Span)
    ceiling.smin = 13
    floor.next = ceiling
    hf.spans[0] = floor
    filter_walkable_low_height_spans(5, &hf)
    testing.expect(
      t,
      floor.area == RC_NULL_AREA,
      "clearance=3 < required=5",
    )
    free(floor)
    free(ceiling)
  }
  // Test 3: Ledge detection
  {
    hf := Heightfield {
      width  = 3,
      height = 1,
      spans  = make([]^Span, 3),
    }
    defer delete(hf.spans)
    for i in 0 ..< 3 {
      span := new(Span)
      span.smax = u32(10 + i * 5) // Heights: 10, 15, 20
      span.area = RC_WALKABLE_AREA
      hf.spans[i] = span
    }
    filter_ledge_spans(10, 3, &hf)
    testing.expect(t, hf.spans[0].area == RC_NULL_AREA, "edge is ledge")
    testing.expect(t, hf.spans[2].area == RC_NULL_AREA, "edge is ledge")
    for i in 0 ..< 3 do free(hf.spans[i])
  }
  // Test 4: Median filter with compact heightfield
  {
    chf := Compact_Heightfield {
      width  = 3,
      height = 3,
    }
    defer {
      delete(chf.cells)
      delete(chf.spans)
      delete(chf.areas)
    }
    chf.cells = make([]Compact_Cell, 9)
    chf.spans = make([]Compact_Span, 9)
    chf.areas = make([]u8, 9)
    for i in 0 ..< 9 {
      chf.cells[i] = {
        index = u32(i),
        count = 1,
      }
      chf.areas[i] = RC_WALKABLE_AREA
      // Setup 4-connected grid
      span := &chf.spans[i]
      x, z := i % 3, i / 3
      for dir in 0 ..< 4 {
        nx := x + int(get_dir_offset_x(dir))
        nz := z + int(get_dir_offset_y(dir))
        if nx >= 0 && nx < 3 && nz >= 0 && nz < 3 {
          // Connection stores index within the neighbor cell's spans
          // Since each cell has exactly 1 span, connection index is 0
          set_con(span, dir, 0)
        } else {
          set_con(span, dir, RC_NOT_CONNECTED)
        }
      }
    }
    chf.areas[4] = RC_NULL_AREA
    median_filter_walkable_area(&chf)
    testing.expect(
      t,
      chf.areas[4] == RC_NULL_AREA,
      "median preserves null",
    )
  }
}

@(test)
test_low_hanging_obstacle_filter_edge_cases :: proc(t: ^testing.T) {
  // Test 1: Height-based climbing (correct approach - agent climbs from smax to smax)
  {
    // Create heightfield with specific spans
    hf := Heightfield {
      width  = 1,
      height = 1,
      bmin   = {0, 0, 0},
      bmax   = {1, 20, 1},
      cs     = 1.0,
      ch     = 1.0,
    }
    hf.spans = make([]^Span, 1)
    // Create walkable floor span [0, 10] - agent stands at height 10
    span1 := new(Span)
    span1.smin = 0
    span1.smax = 10
    span1.area = RC_WALKABLE_AREA
    // Create non-walkable obstacle [12, 15] - agent needs to reach height 15
    span2 := new(Span)
    span2.smin = 12
    span2.smax = 15
    span2.area = RC_NULL_AREA
    span1.next = span2
    hf.spans[0] = span1
    // Apply filter with walkableClimb = 5
    filter_low_hanging_walkable_obstacles(5, &hf)
    // Climb height is 5 (15-10), should be walkable since 5 <= 5
    testing.expect(
      t,
      span2.area != RC_NULL_AREA,
      "Span with climb height=5 should be walkable with walkableClimb=5",
    )
    // Reset and test with walkableClimb = 4
    span2.area = RC_NULL_AREA
    filter_low_hanging_walkable_obstacles(4, &hf)
    // Climb height is 5, should NOT be walkable since 5 > 4
    testing.expect(
      t,
      span2.area == RC_NULL_AREA,
      "Span with climb height=5 should NOT be walkable with walkableClimb=4",
    )
    free(span1)
    free(span2)
    delete(hf.spans)
  }
  // Test 2: Thick platform test
  {
    hf := Heightfield {
      width  = 1,
      height = 1,
      bmin   = {0, 0, 0},
      bmax   = {1, 25, 1},
      cs     = 1.0,
      ch     = 1.0,
    }
    hf.spans = make([]^Span, 1)
    // Create walkable span [0, 10] - agent at height 10
    span1 := new(Span)
    span1.smin = 0
    span1.smax = 10
    span1.area = RC_WALKABLE_AREA
    // Create thick non-walkable platform [11, 20] - agent needs to reach height 20
    span2 := new(Span)
    span2.smin = 11
    span2.smax = 20
    span2.area = RC_NULL_AREA
    span1.next = span2
    hf.spans[0] = span1
    // Apply filter with walkableClimb = 5
    filter_low_hanging_walkable_obstacles(5, &hf)
    // Climb height is 10 (20-10), should NOT be walkable since 10 > 5
    testing.expect(
      t,
      span2.area == RC_NULL_AREA,
      "Thick platform requiring 10 unit climb should not be walkable with walkableClimb=5",
    )
    free(span1)
    free(span2)
    delete(hf.spans)
  }
  // Test 3: Adjacent spans test
  {
    hf := Heightfield {
      width  = 1,
      height = 1,
      bmin   = {0, 0, 0},
      bmax   = {1, 20, 1},
      cs     = 1.0,
      ch     = 1.0,
    }
    hf.spans = make([]^Span, 1)
    // Create walkable span [0, 10]
    span1 := new(Span)
    span1.smin = 0
    span1.smax = 10
    span1.area = RC_WALKABLE_AREA
    // Create adjacent non-walkable span [10, 15]
    span2 := new(Span)
    span2.smin = 10
    span2.smax = 15
    span2.area = RC_NULL_AREA
    span1.next = span2
    hf.spans[0] = span1
    // Apply filter with walkableClimb = 5
    filter_low_hanging_walkable_obstacles(5, &hf)
    // Climb height is 5 (15-10), should be walkable since 5 <= 5
    testing.expect(
      t,
      span2.area != RC_NULL_AREA,
      "Adjacent span with climb=5 should be walkable with walkableClimb=5",
    )
    // Reset and test with smaller walkableClimb
    span2.area = RC_NULL_AREA
    filter_low_hanging_walkable_obstacles(4, &hf)
    // Climb height is 5, should NOT be walkable since 5 > 4
    testing.expect(
      t,
      span2.area == RC_NULL_AREA,
      "Adjacent span with climb=5 should NOT be walkable with walkableClimb=4",
    )
    free(span1)
    free(span2)
    delete(hf.spans)
  }
  // Test 4: Multiple consecutive non-walkable spans
  {
    hf := Heightfield {
      width  = 1,
      height = 1,
      bmin   = {0, 0, 0},
      bmax   = {1, 30, 1},
      cs     = 1.0,
      ch     = 1.0,
    }
    hf.spans = make([]^Span, 1)
    // Create walkable span
    span1 := new(Span)
    span1.smin = 0
    span1.smax = 10
    span1.area = RC_WALKABLE_AREA
    // Create first non-walkable span with small gap
    span2 := new(Span)
    span2.smin = 12
    span2.smax = 15
    span2.area = RC_NULL_AREA
    span1.next = span2
    // Create second non-walkable span with small gap from span2
    span3 := new(Span)
    span3.smin = 17
    span3.smax = 20
    span3.area = RC_NULL_AREA
    span2.next = span3
    hf.spans[0] = span1
    // Apply filter with walkableClimb = 5
    filter_low_hanging_walkable_obstacles(5, &hf)
    // Only span2 should become walkable (gap=2 from span1)
    // span3 should remain non-walkable (it's not directly above a walkable span)
    testing.expect(
      t,
      span2.area != RC_NULL_AREA,
      "First non-walkable span should become walkable",
    )
    testing.expect(
      t,
      span3.area == RC_NULL_AREA,
      "Second non-walkable span should remain non-walkable",
    )
    free(span1)
    free(span2)
    free(span3)
    delete(hf.spans)
  }
  log.info("Low hanging obstacle filter edge cases passed")
}

@(test)
test_ledge_filter_steep_slope :: proc(t: ^testing.T) {
  // Test steep slope detection
  {
    hf := Heightfield {
      width  = 3,
      height = 3,
      bmin   = {0, 0, 0},
      bmax   = {3, 20, 3},
      cs     = 1.0,
      ch     = 1.0,
    }
    hf.spans = make([]^Span, 9)
    // Create a steep slope scenario
    // Center span at height 10
    center_span := new(Span)
    center_span.smin = 0
    center_span.smax = 10
    center_span.area = RC_WALKABLE_AREA
    hf.spans[4] = center_span // Center of 3x3 grid
    // Create neighbors at varying heights
    // Low neighbor at height 7 (traversable)
    low_span := new(Span)
    low_span.smin = 0
    low_span.smax = 7
    low_span.area = RC_WALKABLE_AREA
    hf.spans[3] = low_span // Left neighbor
    // High neighbor at height 11 (traversable)
    high_span := new(Span)
    high_span.smin = 0
    high_span.smax = 11
    high_span.area = RC_WALKABLE_AREA
    hf.spans[5] = high_span // Right neighbor
    walkable_height := 10
    walkable_climb := 3
    // Apply ledge filter
    filter_ledge_spans(walkable_height, walkable_climb, &hf)
    // The center span should be marked as unwalkable because
    // the difference between highest and lowest traversable neighbors (11-7=4) > walkableClimb (3)
    testing.expect(
      t,
      center_span.area == RC_NULL_AREA,
      "Center span should be marked as ledge due to steep slope",
    )
    free(center_span)
    free(low_span)
    free(high_span)
    delete(hf.spans)
  }
  log.info("Ledge filter steep slope test passed")
}

@(test)
test_walkable_low_height_filter :: proc(t: ^testing.T) {
  // Test filtering spans without enough clearance
  {
    hf := Heightfield {
      width  = 1,
      height = 1,
      bmin   = {0, 0, 0},
      bmax   = {1, 20, 1},
      cs     = 1.0,
      ch     = 1.0,
    }
    hf.spans = make([]^Span, 1)
    // Create walkable span with limited clearance
    span1 := new(Span)
    span1.smin = 0
    span1.smax = 10
    span1.area = RC_WALKABLE_AREA
    // Create ceiling span
    span2 := new(Span)
    span2.smin = 13 // Only 3 units of clearance
    span2.smax = 20
    span2.area = RC_NULL_AREA
    span1.next = span2
    hf.spans[0] = span1
    // Apply filter with walkableHeight = 5
    filter_walkable_low_height_spans(5, &hf)
    // span1 should be marked unwalkable (clearance=3 < walkableHeight=5)
    testing.expect(
      t,
      span1.area == RC_NULL_AREA,
      "Span with insufficient clearance should be unwalkable",
    )
    // Reset and test with adequate clearance
    span1.area = RC_WALKABLE_AREA
    span2.smin = 16 // 6 units of clearance
    filter_walkable_low_height_spans(5, &hf)
    // span1 should remain walkable (clearance=6 >= walkableHeight=5)
    testing.expect(
      t,
      span1.area != RC_NULL_AREA,
      "Span with sufficient clearance should remain walkable",
    )
    free(span1)
    free(span2)
    delete(hf.spans)
  }
  log.info("Walkable low height filter test passed")
}

@(test)
test_filter_operations :: proc(t: ^testing.T) {
  hf := create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  defer free_heightfield(hf)
  testing.expect(t, hf != nil, "Heightfield should be created")
  // Create a test scenario with various spans
  // Column with multiple spans at different heights
  add_span(hf, 5, 5, 0, 10, RC_WALKABLE_AREA, 1) // Ground
  add_span(hf, 5, 5, 12, 14, RC_WALKABLE_AREA, 1) // Low overhang
  add_span(hf, 5, 5, 20, 30, RC_WALKABLE_AREA, 1) // Platform
  // Column with ledge
  add_span(hf, 6, 5, 0, 10, RC_WALKABLE_AREA, 1)
  add_span(hf, 6, 5, 11, 12, RC_WALKABLE_AREA, 1) // Thin ledge
  initial_count := 0
  for z in 0 ..< hf.height {
    for x in 0 ..< hf.width {
      s := hf.spans[x + z * hf.width]
      for s != nil {
        if s.area != RC_NULL_AREA {
          initial_count += 1
        }
        s = s.next
      }
    }
  }
  filter_low_hanging_walkable_obstacles(4, hf)
  filter_ledge_spans(10, 4, hf)
  filter_walkable_low_height_spans(10, hf)
  filtered_count := 0
  for z in 0 ..< hf.height {
    for x in 0 ..< hf.width {
      s := hf.spans[x + z * hf.width]
      for s != nil {
        if s.area != RC_NULL_AREA {
          filtered_count += 1
        }
        s = s.next
      }
    }
  }
  testing.expect(
    t,
    filtered_count <= initial_count,
    "Filtering should not increase span count",
  )
}
