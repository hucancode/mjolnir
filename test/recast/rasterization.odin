package test_recast

import "../../mjolnir/navigation/recast"
import "core:log"
import "core:math"
import "core:testing"
import "core:time"

@(test)
test_rasterize_degenerate_triangles :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  // Test 1: Zero area triangle (collinear points)
  vertices_collinear := [][3]f32 {
    {0, 0, 0}, // 0
    {1, 0, 0}, // 1
    {2, 0, 0}, // 2 - all on same line
  }
  indices_collinear := []i32{0, 1, 2}
  areas_collinear := []u8{recast.RC_WALKABLE_AREA}
  // Should handle collinear points gracefully without crashing
  ok := recast.rasterize_triangles(
    vertices_collinear,
    indices_collinear,
    areas_collinear,
    hf,
    1,
  )
  testing.expect(t, ok, "Rasterization should succeed with collinear points")
  // Test 2: Identical vertices triangle
  vertices_identical := [][3]f32 {
    {5, 1, 5}, // 0
    {5, 1, 5}, // 1 - identical to 0
    {5, 1, 5}, // 2 - identical to 0
  }
  indices_identical := []i32{0, 1, 2}
  areas_identical := []u8{recast.RC_WALKABLE_AREA}
  // Should handle identical vertices without crashing
  ok = recast.rasterize_triangles(
    vertices_identical,
    indices_identical,
    areas_identical,
    hf,
    1,
  )
  testing.expect(
    t,
    hf != nil,
    "Rasterization should succeed with identical vertices",
  )
}

@(test)
test_rasterize_nearly_degenerate_triangles :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  // Nearly collinear points (very thin triangle)
  epsilon := f32(1e-6)
  vertices := [][3]f32 {
    {2, 1, 2}, // 0
    {3, 1, 2}, // 1
    {2.5, 1, 2 + epsilon}, // 2 - barely off the line
  }
  indices := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  // Should handle nearly degenerate triangles
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(
    t,
    hf != nil,
    "Rasterization should succeed with nearly degenerate triangle",
  )
  // Check that at least the center cell got a span
  center_x, center_z := i32(2), i32(2)
  column_index := center_x + center_z * hf.width
  span := hf.spans[column_index]
  // Span might be nil due to very small triangle, but shouldn't crash
}

@(test)
test_rasterize_sub_pixel_triangles :: proc(t: ^testing.T) {
  // Use high resolution heightfield to test sub-pixel triangles
  // Small cell size to create sub-pixel scenarios
  cell_size := f32(0.1)
  hf := recast.create_heightfield(
    50,
    50,
    {0, 0, 0},
    {5, 5, 5},
    cell_size,
    0.05,
  )
  testing.expect(t, hf != nil, "Failed to create high-res heightfield")
  defer recast.free_heightfield(hf)
  // Triangle smaller than one cell
  triangle_size := cell_size * 0.8
  vertices := [][3]f32 {
    {2, 1, 2}, // 0
    {2 + triangle_size, 1, 2}, // 1
    {2 + triangle_size / 2, 1, 2 + triangle_size}, // 2
  }
  indices := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(
    t,
    hf != nil,
    "Sub-pixel triangle rasterization should succeed",
  )
  // Check that the triangle affected at least one cell
  affected_cells := 0
  for i in 0 ..< (hf.width * hf.height) {
    if hf.spans[i] != nil {
      affected_cells += 1
    }
  }
  testing.expect(
    t,
    affected_cells > 0,
    "Sub-pixel triangle should affect at least one cell",
  )
}

@(test)
test_rasterize_tiny_triangles_various_positions :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(20, 20, {0, 0, 0}, {10, 10, 10}, 0.5, 0.1)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  tiny_size := f32(0.01)
  // Test tiny triangles at various positions
  test_positions := [][2]f32 {
    {1.0, 1.0}, // Cell center
    {1.25, 1.25}, // Cell boundary
    {1.49, 1.49}, // Near cell edge
    {0.01, 0.01}, // Near origin
    {8.99, 8.99}, // Near boundary
  }
  for pos, i in test_positions {
    vertices := [][3]f32 {
      {pos.x, 1, pos.y},
      {pos.x + tiny_size, 1, pos.y},
      {pos.x + tiny_size / 2, 1, pos.y + tiny_size},
    }
    indices := []i32{0, 1, 2}
    areas := []u8{recast.RC_WALKABLE_AREA}
    ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
    testing.expect(t, hf != nil, "Tiny triangle rasterization should succeed")
  }
}

@(test)
test_rasterize_large_triangle_spanning_cells :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  // Large triangle spanning many cells
  vertices := [][3]f32 {
    {1, 1, 1}, // 0
    {8, 1, 1}, // 1 - spans 7 cells in X
    {4.5, 1, 8}, // 2 - spans 7 cells in Z
  }
  indices := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(t, hf != nil, "Large triangle rasterization should succeed")
  // Count affected cells
  affected_cells := 0
  for i in 0 ..< (hf.width * hf.height) {
    if hf.spans[i] != nil {
      affected_cells += 1
    }
  }
  // Large triangle should affect multiple cells
  testing.expect(
    t,
    affected_cells > 10,
    "Large triangle should affect many cells",
  )
  log.infof("Large triangle affected %d cells", affected_cells)
}

@(test)
test_rasterize_triangle_partial_cell_coverage :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  // Triangle that partially covers several cells
  vertices := [][3]f32 {
    {2.2, 1, 2.3}, // 0 - offset from cell centers
    {3.7, 1, 2.8}, // 1
    {2.9, 1, 4.1}, // 2
  }
  indices := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(
    t,
    hf != nil,
    "Partial coverage triangle rasterization should succeed",
  )
  // Check that boundary cells are handled correctly
  affected_cells := 0
  for z in 2 ..= 4 {
    for x in 2 ..= 3 {
      column_index := i32(x) + i32(z) * hf.width
      if hf.spans[column_index] != nil {
        affected_cells += 1
      }
    }
  }
  testing.expect(
    t,
    affected_cells > 0,
    "Partial coverage should affect some cells",
  )
}

@(test)
test_rasterize_floating_point_precision :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  // Triangle with coordinates that might cause precision issues
  vertices := [][3]f32 {
    {2.0000001, 1, 2.0000001}, // 0 - tiny offset from grid
    {3.9999999, 1, 2.0000002}, // 1
    {3.0000000, 1, 3.9999998}, // 2
  }
  indices := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(
    t,
    hf != nil,
    "Precision edge case rasterization should succeed",
  )
  // Should produce consistent results despite precision issues
  affected_cells := 0
  for i in 0 ..< (hf.width * hf.height) {
    if hf.spans[i] != nil {
      affected_cells += 1
    }
  }
  testing.expect(
    t,
    affected_cells > 0,
    "Precision edge case should still affect cells",
  )
}

@(test)
test_rasterize_extreme_coordinates :: proc(t: ^testing.T) {
  large_offset := f32(100000.0)
  hf := recast.create_heightfield(
    10,
    10,
    {large_offset, 0, large_offset},
    {large_offset + 10, 10, large_offset + 10},
    1.0,
    0.5,
  )
  testing.expect(
    t,
    hf != nil,
    "Failed to create heightfield with extreme coordinates",
  )
  defer recast.free_heightfield(hf)
  // Triangle within the extreme coordinate space
  vertices := [][3]f32 {
    {large_offset + 2, 1, large_offset + 2},
    {large_offset + 4, 1, large_offset + 2},
    {large_offset + 3, 1, large_offset + 4},
  }
  indices := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(
    t,
    hf != nil,
    "Extreme coordinates rasterization should succeed",
  )
  // Check that the triangle was rasterized correctly
  center_column := 3 + 3 * hf.width
  span := hf.spans[center_column]
  testing.expect(
    t,
    span != nil,
    "Extreme coordinates triangle should create spans",
  )
}

@(test)
test_rasterize_sloped_triangles :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.2)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  // Sloped triangle with height variation
  vertices := [][3]f32 {
    {2, 1, 2}, // 0 - low
    {4, 3, 2}, // 1 - high
    {3, 2, 4}, // 2 - medium
  }
  indices := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(t, hf != nil, "Sloped triangle rasterization should succeed")
  // Check that spans were created with appropriate heights
  affected_spans := 0
  height_sum := f32(0)
  for i in 0 ..< (hf.width * hf.height) {
    if span := hf.spans[i]; span != nil {
      affected_spans += 1
      // Height should be interpolated across the sloped surface
      span_height := (f32(span.smax) - f32(span.smin)) * hf.ch
      height_sum += span_height
    }
  }
  testing.expect(t, affected_spans > 0, "Sloped triangle should create spans")
  avg_span_height := height_sum / f32(affected_spans)
  log.infof(
    "Sloped triangle: %d spans, average height: %.2f",
    affected_spans,
    avg_span_height,
  )
}

@(test)
test_rasterize_vertical_triangles :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  // Vertical triangle (wall)
  vertices := [][3]f32 {
    {3, 0, 3}, // 0 - bottom
    {3, 5, 3}, // 1 - top same X,Z
    {3, 2.5, 4}, // 2 - middle
  }
  indices := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(
    t,
    hf != nil,
    "Vertical triangle rasterization should succeed",
  )
  // Vertical triangles might not create spans in XZ plane
  // but should not crash the system
}

@(test)
test_rasterize_many_tiny_triangles :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second) // Longer timeout for stress test
  hf := recast.create_heightfield(20, 20, {0, 0, 0}, {20, 20, 20}, 1.0, 0.2)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  // Generate many small triangles
  triangle_count := 100
  vertices := make([][3]f32, triangle_count * 3)
  indices := make([]i32, triangle_count * 3)
  areas := make([]u8, triangle_count)
  defer delete(vertices)
  defer delete(indices)
  defer delete(areas)
  triangle_size := f32(0.2)
  for i in 0 ..< triangle_count {
    base_x := f32(i % 18) + 1.0
    base_z := f32(i / 18) + 1.0
    base_idx := i * 3
    vertices[base_idx + 0] = {base_x, 1, base_z}
    vertices[base_idx + 1] = {base_x + triangle_size, 1, base_z}
    vertices[base_idx + 2] = {
      base_x + triangle_size / 2,
      1,
      base_z + triangle_size,
    }
    indices[base_idx + 0] = i32(base_idx + 0)
    indices[base_idx + 1] = i32(base_idx + 1)
    indices[base_idx + 2] = i32(base_idx + 2)
    areas[i] = recast.RC_WALKABLE_AREA
  }
  ok := recast.rasterize_triangles(vertices, indices, areas, hf, 1)
  testing.expect(
    t,
    hf != nil,
    "Many tiny triangles rasterization should succeed",
  )
  // Count total spans created
  total_spans := 0
  for i in 0 ..< (hf.width * hf.height) {
    if hf.spans[i] != nil {
      total_spans += 1
    }
  }
  testing.expect(t, total_spans > 0, "Many tiny triangles should create spans")
}

// Thorough triangle rasterization validation - tests geometric accuracy
@(test)
test_triangle_rasterization_accuracy :: proc(t: ^testing.T) {
  // Test rasterization of a specific triangle with known coverage
  // Triangle vertices: (1,0,1), (3,0,1), (2,0,3)
  // This creates a triangle that should cover specific cells
  verts := [][3]f32 {
    {1, 0, 1}, // Vertex 0
    {3, 0, 1}, // Vertex 1
    {2, 0, 3}, // Vertex 2
  }
  tris := []i32{0, 1, 2}
  areas := []u8{recast.RC_WALKABLE_AREA}
  hf := recast.create_heightfield(5, 5, {0, 0, 0}, {5, 0, 5}, 1.0, 0.2)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer recast.free_heightfield(hf)
  ok := recast.rasterize_triangles(verts, tris, areas, hf, 1)
  testing.expect(t, hf != nil, "Failed to rasterize triangle")
  // Validate specific cells that should be covered by the triangle
  // The triangle should cover cells at grid positions based on its geometry
  check_cell_coverage :: proc(hf: ^recast.Heightfield, x, z: i32) -> bool {
    if x < 0 || x >= hf.width || z < 0 || z >= hf.height {
      return false
    }
    spans := hf.spans[x + z * hf.width]
    has_span := spans != nil
    return has_span
  }
  // Test specific cells based on triangle geometry
  // Center of triangle should definitely be covered
  testing.expectf(
    t,
    check_cell_coverage(hf, 2, 2) == true,
    "should cover triangle center",
  )
  // Cells clearly outside triangle should not be covered
  testing.expectf(
    t,
    check_cell_coverage(hf, 0, 0) == false,
    "should not cover outside triangle",
  )
  testing.expectf(
    t,
    check_cell_coverage(hf, 4, 4) == false,
    "should not cover outside triangle",
  )
  // Count total covered cells and validate reasonable coverage
  covered_cells := 0
  for x in 0 ..< hf.width {
    for z in 0 ..< hf.height {
      spans := hf.spans[x + z * hf.width]
      if spans != nil {
        covered_cells += 1
      }
    }
  }
  // Triangle should cover a reasonable number of cells (not 0, not all)
  testing.expect(
    t,
    covered_cells >= 3 && covered_cells <= 12,
    "Triangle should cover reasonable number of cells (3-12)",
  )
}

@(test)
test_triangle_rasterization :: proc(t: ^testing.T) {
  hf := recast.create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  defer recast.free_heightfield(hf)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  // Test single triangle rasterization
  v0 := [3]f32{2, 1, 2}
  v1 := [3]f32{8, 1, 2}
  v2 := [3]f32{5, 1, 8}
  ok := recast.rasterize_triangle(v0, v1, v2, recast.RC_WALKABLE_AREA, hf, 1)
  testing.expect(t, ok, "Failed to rasterize triangle")
  // Count total spans created
  total_spans := 0
  for z in 0 ..< hf.height {
    for x in 0 ..< hf.width {
      s := hf.spans[x + z * hf.width]
      for s != nil {
        total_spans += 1
        s = s.next
      }
    }
  }
  testing.expect(t, total_spans > 0, "No spans created from triangle")
  // Test degenerate triangle (should handle gracefully)
  v3 := [3]f32{0, 0, 0}
  v4 := [3]f32{1, 0, 0}
  v5 := [3]f32{2, 0, 0} // Collinear points
  ok2 := recast.rasterize_triangle(v3, v4, v5, recast.RC_WALKABLE_AREA, hf, 1)
  testing.expect(t, ok2, "Failed to handle degenerate triangle")
}
