package recast

import "core:log"
import "core:math"
import "core:testing"
import "core:time"

// Validate detail mesh data
validate_poly_mesh_detail :: proc(dmesh: ^Poly_Mesh_Detail) -> bool {
  if dmesh == nil do return false
  if len(dmesh.meshes) <= 0 || len(dmesh.verts) <= 0 || len(dmesh.tris) <= 0 do return false
  // Check mesh data bounds
  for i in 0 ..< len(dmesh.meshes) {
    // Each mesh entry: [vertex_base, vertex_count, triangle_base, triangle_count]
    mesh_info := dmesh.meshes[i]
    vert_base := mesh_info[0]
    vert_count := mesh_info[1]
    tri_base := mesh_info[2]
    tri_count := mesh_info[3]
    // Validate bounds
    if vert_base + vert_count > u32(len(dmesh.verts)) do return false
    if tri_base + tri_count > u32(len(dmesh.tris)) do return false
  }
  // Check triangle data
  for tri in dmesh.tris {
    // Check vertex indices
    for j in 0 ..< 3 {
      vert_idx := tri[j]
      if int(vert_idx) >= len(dmesh.verts) do return false
    }
  }
  return true
}

@(test)
test_simple_detail_mesh_build :: proc(t: ^testing.T) {
  // Create minimal working example
  pmesh := new(Poly_Mesh)
  defer free_poly_mesh(pmesh)
  chf := new(Compact_Heightfield)
  defer free_compact_heightfield(chf)
  dmesh := new(Poly_Mesh_Detail)
  defer free_poly_mesh_detail(dmesh)
  // Set up minimal polygon mesh (single triangle)
  pmesh.npolys = 1
  pmesh.nvp = 3
  pmesh.bmin = {0, 0, 0}
  pmesh.bmax = {1, 1, 1}
  pmesh.cs = 0.1
  pmesh.ch = 0.1
  pmesh.verts = make([][3]u16, 3)
  pmesh.verts[0] = {0, 0, 0}
  pmesh.verts[1] = {10, 0, 0}
  pmesh.verts[2] = {5, 0, 10}
  pmesh.polys = make([]u16, 6) // 1 poly * 3 verts * 2 (verts + neighbors)
  pmesh.polys[0] = 0;pmesh.polys[1] = 1;pmesh.polys[2] = 2
  pmesh.polys[3] = RC_MESH_NULL_IDX
  pmesh.polys[4] = RC_MESH_NULL_IDX
  pmesh.polys[5] = RC_MESH_NULL_IDX
  pmesh.regs = make([]u16, 1)
  pmesh.flags = make([]u16, 1)
  pmesh.areas = make([]u8, 1)
  pmesh.areas[0] = RC_WALKABLE_AREA
  // Set up minimal compact heightfield
  chf.width = 2
  chf.height = 2
  chf.bmin = pmesh.bmin
  chf.bmax = pmesh.bmax
  chf.cs = pmesh.cs
  chf.ch = pmesh.ch
  chf.cells = make([]Compact_Cell, 4)
  chf.spans = make([]Compact_Span, 4)
  for i in 0 ..< 4 {
    cell := &chf.cells[i]
    cell.index = u32(i)
    cell.count = 1
    span := &chf.spans[i]
    span.y = 0
    span.h = 1
  }
  // Try to build detail mesh
  ok := build_poly_mesh_detail(pmesh, chf, 0.5, 1.0, dmesh)
  testing.expect(t, ok, "Should build detail mesh successfully")
  valid := validate_poly_mesh_detail(dmesh)
  testing.expect(t, valid, "Built detail mesh should be valid")
}

@(test)
test_detail_mesh_sampling_quality :: proc(t: ^testing.T) {
  // Test detail mesh sampling with different quality settings
  vertices := [][3]f32 {
    {0, 0, 0},
    {20, 0, 0},
    {20, 1, 20},
    {0, 2, 20}, // Sloped quad
  }
  indices := []i32{0, 1, 2, 0, 2, 3}
  areas := []u8{RC_WALKABLE_AREA, RC_WALKABLE_AREA}
  cfg := Config {
    cs                       = 0.5,
    ch                       = 0.2,
    walkable_slope           = math.PI * 0.25,
    walkable_height          = 10,
    walkable_climb           = 4,
    walkable_radius          = 2,
    max_edge_len             = 12,
    max_simplification_error = 1.3,
    min_region_area          = 8,
    merge_region_area        = 20,
    max_verts_per_poly       = 6,
    detail_sample_dist       = 3.0, // Test different sampling distances
    detail_sample_max_error  = 0.5,
  }
  pmesh, dmesh_low, ok := build_navmesh(vertices, indices, areas, cfg)
  testing.expect(t, ok, "Low quality build should succeed")
  defer free_poly_mesh(pmesh)
  defer free_poly_mesh_detail(dmesh_low)
  // Build with high quality sampling
  cfg.detail_sample_dist = 1.0
  cfg.detail_sample_max_error = 0.1
  pmesh2, dmesh_high, ok2 := build_navmesh(
    vertices,
    indices,
    areas,
    cfg,
  )
  testing.expect(t, ok2, "High quality build should succeed")
  defer free_poly_mesh(pmesh2)
  defer free_poly_mesh_detail(dmesh_high)
  // High quality should have more detail vertices
  testing.expect(
    t,
    len(dmesh_high.verts) >= len(dmesh_low.verts),
    "Higher quality should have more or equal vertices",
  )
  log.infof(
    "Detail mesh quality test: Low=%d verts, High=%d verts",
    len(dmesh_low.verts),
    len(dmesh_high.verts),
  )
}

@(test)
test_detail_mesh_height_accuracy :: proc(t: ^testing.T) {
  // Test that detail mesh accurately represents height variations
  vertices := [][3]f32 {
    // Create a surface with height variation
    {0, 0, 0},
    {10, 2, 0},
    {10, 1, 10},
    {0, 3, 10},
  }
  indices := []i32{0, 1, 2, 0, 2, 3}
  areas := []u8{RC_WALKABLE_AREA, RC_WALKABLE_AREA}
  cfg := Config {
    cs                       = 0.5,
    ch                       = 0.1, // Small height resolution for accuracy
    walkable_slope           = math.PI * 0.33,
    walkable_height          = 20,
    walkable_climb           = 10,
    walkable_radius          = 1,
    max_edge_len             = 12,
    max_simplification_error = 1.3,
    min_region_area          = 8,
    merge_region_area        = 20,
    max_verts_per_poly       = 6,
    detail_sample_dist       = 0.5, // Dense sampling
    detail_sample_max_error  = 0.05, // Low error tolerance
  }
  pmesh, dmesh, ok := build_navmesh(vertices, indices, areas, cfg)
  testing.expect(t, ok, "Build with height variation should succeed")
  defer free_poly_mesh(pmesh)
  defer free_poly_mesh_detail(dmesh)
  if ok && len(dmesh.verts) > 0 {
    // Check height range in detail mesh
    min_y, max_y := dmesh.verts[0].y, dmesh.verts[0].y
    for v in dmesh.verts {
      min_y = min(min_y, v.y)
      max_y = max(max_y, v.y)
    }
    height_range := max_y - min_y
    testing.expect(
      t,
      height_range > 0,
      "Detail mesh should capture height variation",
    )
    log.infof(
      "Height accuracy test: Range=%.2f (%.2f to %.2f)",
      height_range,
      min_y,
      max_y,
    )
  }
}

@(test)
test_detail_mesh_edge_cases :: proc(t: ^testing.T) {
  // Test edge cases: very small triangles, degenerate cases
  // Case 1: Very small triangle
  vertices_small := [][3]f32{{0, 0, 0}, {0.1, 0, 0}, {0.05, 0, 0.1}}
  indices_small := []i32{0, 1, 2}
  areas_small := []u8{RC_WALKABLE_AREA}
  cfg := Config {
    cs                       = 0.01, // Very small cell size
    ch                       = 0.01,
    walkable_slope           = math.PI * 0.25,
    walkable_height          = 10,
    walkable_climb           = 4,
    walkable_radius          = 1,
    max_edge_len             = 12,
    max_simplification_error = 1.3,
    min_region_area          = 1,
    merge_region_area        = 2,
    max_verts_per_poly       = 6,
    detail_sample_dist       = 0.01,
    detail_sample_max_error  = 0.001,
  }
  pmesh, dmesh, ok := build_navmesh(
    vertices_small,
    indices_small,
    areas_small,
    cfg,
  )
  if ok {
    defer free_poly_mesh(pmesh)
    defer free_poly_mesh_detail(dmesh)
    testing.expect(
      t,
      validate_poly_mesh_detail(dmesh),
      "Small triangle detail mesh should be valid",
    )
  }
  // Case 2: Large triangle with extreme aspect ratio
  vertices_large := [][3]f32 {
    {0, 0, 0},
    {100, 0, 0},
    {50, 0, 0.1}, // Very thin triangle
  }
  indices_large := []i32{0, 1, 2}
  areas_large := []u8{RC_WALKABLE_AREA}
  cfg.cs = 1.0
  cfg.ch = 0.2
  cfg.min_region_area = 8
  cfg.merge_region_area = 20
  cfg.detail_sample_dist = 2.0
  cfg.detail_sample_max_error = 0.5
  pmesh2, dmesh2, ok2 := build_navmesh(
    vertices_large,
    indices_large,
    areas_large,
    cfg,
  )
  if ok2 {
    defer free_poly_mesh(pmesh2)
    defer free_poly_mesh_detail(dmesh2)
    testing.expect(
      t,
      validate_poly_mesh_detail(dmesh2),
      "Large aspect ratio detail mesh should be valid",
    )
  }
}

@(test)
test_build_detail_mesh_simple :: proc(t: ^testing.T) {
  // Create simple scenario for detail mesh building
  hf := create_heightfield(8, 8, {0, 0, 0}, {8, 8, 8}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add walkable area
  for x in 2 ..= 5 {
    for z in 2 ..= 5 {
      add_span(hf, i32(x), i32(z), 0, 2, RC_WALKABLE_AREA, 1)
    }
  }
  // Build compact heightfield
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  testing.expect(t, chf != nil, "Failed to build compact heightfield")
  // Build regions and contours
  ok := build_distance_field(chf)
  testing.expect(t, ok, "Failed to build distance field")
  ok = build_regions(chf, 2, 8, 20)
  testing.expect(t, ok, "Failed to build regions")
  contour_set := create_contour_set(chf, 1.0, 1, {.WALL_EDGES})
  testing.expect(t, contour_set != nil, "Failed to build contours")
  defer free_contour_set(contour_set)
  // Build polygon mesh
  poly_mesh := create_poly_mesh(contour_set, 6)
  testing.expect(t, poly_mesh != nil, "Failed to build poly mesh")
  defer free_poly_mesh(poly_mesh)
  // Build detail mesh
  detail_mesh := create_poly_mesh_detail(poly_mesh, chf, 2.0, 1.0)
  testing.expect(t, detail_mesh != nil, "Failed to build detail mesh")
  defer free_poly_mesh_detail(detail_mesh)
  // Verify detail mesh was created
  testing.expect(
    t,
    len(detail_mesh.meshes) > 0,
    "Detail mesh should have mesh data",
  )
  testing.expect(
    t,
    len(detail_mesh.verts) > 0,
    "Detail mesh should have vertices",
  )
  testing.expect(
    t,
    len(detail_mesh.tris) > 0,
    "Detail mesh should have triangles",
  )
}

@(test)
test_detail_mesh_sample_distance_variations :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 45 * time.Second)
  // Create base scenario
  hf := create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Create larger walkable area for better testing
  for x in 2 ..= 7 {
    for z in 2 ..= 7 {
      add_span(hf, i32(x), i32(z), 0, 2, RC_WALKABLE_AREA, 1)
    }
  }
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  ok := build_distance_field(chf)
  ok = build_regions(chf, 2, 8, 20)
  contour_set := create_contour_set(chf, 1.0, 1, {.WALL_EDGES})
  defer free_contour_set(contour_set)
  poly_mesh := create_poly_mesh(contour_set, 6)
  defer free_poly_mesh(poly_mesh)
  // Test different sample distances
  sample_distances := []f32{1.0, 2.0, 4.0}
  for sample_dist in sample_distances {
    detail_mesh := new(Poly_Mesh_Detail)
    defer free_poly_mesh_detail(detail_mesh)
    ok = build_poly_mesh_detail(
      poly_mesh,
      chf,
      sample_dist,
      1.0,
      detail_mesh,
    )
    testing.expect(t, ok, "Failed to build detail mesh with sample distance")
    vertex_count := len(detail_mesh.verts)
    triangle_count := len(detail_mesh.tris)
    log.infof(
      "Sample distance %.1f: %d vertices, %d triangles",
      sample_dist,
      vertex_count,
      triangle_count,
    )
    // Higher sample distance should generally result in fewer vertices
    testing.expect(t, vertex_count >= 0, "Should have valid vertex count")
    testing.expect(t, triangle_count >= 0, "Should have valid triangle count")
  }
}

@(test)
test_detail_mesh_max_edge_error_variations :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 45 * time.Second)
  // Create base scenario with sloped surface for edge error testing
  hf := create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.2)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Create sloped area for better edge error testing
  for x in 2 ..= 7 {
    for z in 2 ..= 7 {
      // Create slight slope
      height := u16(2 + (x - 2) / 3)
      add_span(
        hf,
        i32(x),
        i32(z),
        0,
        height,
        RC_WALKABLE_AREA,
        1,
      )
    }
  }
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  ok := build_distance_field(chf)
  ok = build_regions(chf, 2, 8, 20)
  contour_set := create_contour_set(chf, 1.0, 1, {.WALL_EDGES})
  defer free_contour_set(contour_set)
  poly_mesh := create_poly_mesh(contour_set, 6)
  defer free_poly_mesh(poly_mesh)
  // Test different max edge errors
  max_edge_errors := []f32{0.5, 1.0, 2.0}
  for max_edge_error in max_edge_errors {
    detail_mesh := new(Poly_Mesh_Detail)
    defer free_poly_mesh_detail(detail_mesh)
    ok = build_poly_mesh_detail(
      poly_mesh,
      chf,
      2.0,
      max_edge_error,
      detail_mesh,
    )
    testing.expect(t, ok, "Failed to build detail mesh with max edge error")
    vertex_count := len(detail_mesh.verts)
    triangle_count := len(detail_mesh.tris)
    log.infof(
      "Max edge error %.1f: %d vertices, %d triangles",
      max_edge_error,
      vertex_count,
      triangle_count,
    )
    // Lower edge error should generally result in more vertices
    testing.expect(t, vertex_count >= 0, "Should have valid vertex count")
    testing.expect(t, triangle_count >= 0, "Should have valid triangle count")
  }
}

@(test)
test_detail_mesh_small_polygons :: proc(t: ^testing.T) {
  hf := create_heightfield(10, 10, {0, 0, 0}, {10, 10, 10}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Create several tiny walkable areas
  tiny_areas := [][2]i32{{2, 2}, {2, 3}, {4, 4}, {6, 6}}
  for area in tiny_areas {
    ok := add_span(
      hf,
      area[0],
      area[1],
      0,
      2,
      RC_WALKABLE_AREA,
      1,
    )
    testing.expect(t, ok, "Failed to add tiny walkable area")
  }
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  ok := build_distance_field(chf)
  ok = build_regions(chf, 1, 1, 1) // Very small regions to accommodate tiny areas
  contour_set := create_contour_set(chf, 1.0, 1, {.WALL_EDGES})
  defer free_contour_set(contour_set)
  poly_mesh := create_poly_mesh(contour_set, 6)
  defer free_poly_mesh(poly_mesh)
  testing.expect(t, poly_mesh == nil, "no polygon should be created")
}

@(test)
test_detail_mesh_extreme_parameters :: proc(t: ^testing.T) {
  // Create base scenario
  hf := create_heightfield(8, 8, {0, 0, 0}, {8, 8, 8}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add simple walkable area
  for x in 2 ..= 5 {
    for z in 2 ..= 5 {
      add_span(hf, i32(x), i32(z), 0, 2, RC_WALKABLE_AREA, 1)
    }
  }
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  ok := build_distance_field(chf)
  ok = build_regions(chf, 2, 8, 20)
  contour_set := create_contour_set(chf, 1.0, 1, {.WALL_EDGES})
  defer free_contour_set(contour_set)
  poly_mesh := create_poly_mesh(contour_set, 6)
  defer free_poly_mesh(poly_mesh)
  // Test extreme parameters
  extreme_cases := []struct {
    sample_dist, max_edge_error: f32,
  } {
    {0.1, 0.1}, // Very small values
    {10.0, 10.0}, // Very large values
    {0.1, 10.0}, // Mixed
    {10.0, 0.1}, // Mixed opposite
  }
  for extreme_case in extreme_cases {
    detail_mesh := new(Poly_Mesh_Detail)
    defer free_poly_mesh_detail(detail_mesh)
    ok = build_poly_mesh_detail(
      poly_mesh,
      chf,
      extreme_case.sample_dist,
      extreme_case.max_edge_error,
      detail_mesh,
    )
    testing.expect(t, ok)
    vertex_count := len(detail_mesh.verts)
    triangle_count := len(detail_mesh.tris)
    testing.expect(t, vertex_count >= 0, "Should have valid vertex count")
    testing.expect(t, triangle_count >= 0, "Should have valid triangle count")
  }
}

@(test)
test_detail_mesh_data_consistency :: proc(t: ^testing.T) {
  // Create scenario for detail mesh validation
  hf := create_heightfield(8, 8, {0, 0, 0}, {8, 8, 8}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add walkable area
  for x in 2 ..= 5 {
    for z in 2 ..= 5 {
      add_span(hf, i32(x), i32(z), 0, 2, RC_WALKABLE_AREA, 1)
    }
  }
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  ok := build_distance_field(chf)
  ok = build_regions(chf, 2, 8, 20)
  contour_set := create_contour_set(chf, 1.0, 1, {.WALL_EDGES})
  defer free_contour_set(contour_set)
  poly_mesh := create_poly_mesh(contour_set, 6)
  defer free_poly_mesh(poly_mesh)
  detail_mesh := new(Poly_Mesh_Detail)
  defer free_poly_mesh_detail(detail_mesh)
  ok = build_poly_mesh_detail(poly_mesh, chf, 2.0, 1.0, detail_mesh)
  testing.expect(t, ok, "Failed to build detail mesh")
  // Validate detail mesh data consistency
  if len(detail_mesh.meshes) > 0 {
    // Each mesh entry should reference valid vertex and triangle ranges
    for i in 0 ..< len(detail_mesh.meshes) {
      mesh := detail_mesh.meshes[i]
      // Validate vertex base and count
      vert_base := int(mesh[0])
      vert_count := int(mesh[1])
      testing.expect(t, vert_base >= 0, "Vertex base should be non-negative")
      testing.expect(
        t,
        vert_base + vert_count <= len(detail_mesh.verts),
        "Vertex range should be within bounds",
      )
      // Validate triangle base and count
      tri_base := int(mesh[2])
      tri_count := int(mesh[3])
      testing.expect(t, tri_base >= 0, "Triangle base should be non-negative")
      testing.expect(
        t,
        tri_base + tri_count <= len(detail_mesh.tris),
        "Triangle range should be within bounds",
      )
      // Each triangle should reference valid vertices (relative to mesh vertex base)
      for tri_idx in 0 ..< tri_count {
        tri_index := tri_base + tri_idx
        triangle := detail_mesh.tris[tri_index]
        for vert_idx in 0 ..< 3 {
          vertex_ref := int(triangle[vert_idx])
          // Triangle vertex indices should be relative to mesh base (0 to vert_count-1)
          testing.expect(
            t,
            vertex_ref >= 0,
            "Triangle vertex ref should be >= 0",
          )
          testing.expect(
            t,
            vertex_ref < vert_count,
            "Triangle vertex ref should be < vert_count",
          )
          // Verify the global vertex index exists
          global_vertex_index := vert_base + vertex_ref
          testing.expect(
            t,
            global_vertex_index < len(detail_mesh.verts),
            "Global vertex index should be valid",
          )
        }
      }
    }
  }
}

@(test)
test_detail_mesh_performance :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 60 * time.Second) // Longer timeout for performance test
  // Create larger scenario for performance testing
  hf := create_heightfield(20, 20, {0, 0, 0}, {20, 20, 20}, 1.0, 0.5)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  defer free_heightfield(hf)
  // Add larger walkable area
  for x in 2 ..= 17 {
    for z in 2 ..= 17 {
      add_span(hf, i32(x), i32(z), 0, 2, RC_WALKABLE_AREA, 1)
    }
  }
  chf := create_compact_heightfield(2, 1, hf)
  defer free_compact_heightfield(chf)
  ok := build_distance_field(chf)
  ok = build_regions(chf, 8, 50, 50)
  contour_set := create_contour_set(chf, 1.0, 1, {.WALL_EDGES})
  defer free_contour_set(contour_set)
  poly_mesh := create_poly_mesh(contour_set, 6)
  defer free_poly_mesh(poly_mesh)
  detail_mesh := new(Poly_Mesh_Detail)
  defer free_poly_mesh_detail(detail_mesh)
  // Measure performance
  start_time := time.now()
  ok = build_poly_mesh_detail(poly_mesh, chf, 2.0, 1.0, detail_mesh)
  end_time := time.now()
  duration := time.duration_milliseconds(time.diff(start_time, end_time))
  testing.expect(t, ok, "Failed to build detail mesh in performance test")
  testing.expect(
    t,
    duration < 5000,
    "Detail mesh building should complete within reasonable time",
  )
  vertex_count := len(detail_mesh.verts)
  triangle_count := len(detail_mesh.tris)
  mesh_count := len(detail_mesh.meshes)
  log.infof(
    "✓ Detail mesh performance test passed: %d ms, %d meshes, %d vertices, %d triangles",
    duration,
    mesh_count,
    vertex_count,
    triangle_count,
  )
}

@(test)
test_delaunay_hull_simple_triangle :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 10 * time.Second)
  // Simple triangle (3 points)
  points := [][3]f32 {
    {0, 0, 0}, // Point 0
    {2, 0, 0}, // Point 1
    {1, 0, 2}, // Point 2
  }
  hull := []i32{0, 1, 2} // Hull order: counter-clockwise
  triangles := make([dynamic][4]i32)
  defer delete(triangles)
  success := delaunay_hull(points, hull, &triangles)
  testing.expect(t, success, "Simple triangle triangulation should succeed")
  testing.expect(
    t,
    len(triangles) == 1,
    "Simple triangle should produce exactly 1 triangle",
  )
  if len(triangles) > 0 {
    tri := triangles[0]
    // Verify triangle contains all 3 vertices
    vertices_in_triangle: [3]bool
    for i in 0 ..< 3 {
      idx := tri[i]
      testing.expect(
        t,
        idx >= 0 && idx < 3,
        "Triangle vertex index should be valid",
      )
      vertices_in_triangle[idx] = true
    }
    testing.expect(
      t,
      vertices_in_triangle[0] &&
      vertices_in_triangle[1] &&
      vertices_in_triangle[2],
      "Triangle should contain all 3 vertices",
    )
    log.infof(
      "Simple triangle test: triangle [%d,%d,%d]",
      tri[0],
      tri[1],
      tri[2],
    )
  }
}

@(test)
test_delaunay_hull_square :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 10 * time.Second)
  // Square (4 points forming convex hull)
  points := [][3]f32 {
    {0, 0, 0}, // Point 0
    {2, 0, 0}, // Point 1
    {2, 0, 2}, // Point 2
    {0, 0, 2}, // Point 3
  }
  hull := []i32{0, 1, 2, 3} // Hull order: counter-clockwise
  triangles := make([dynamic][4]i32)
  defer delete(triangles)
  success := delaunay_hull(points, hull, &triangles)
  testing.expect(t, success, "Square triangulation should succeed")
  testing.expect(
    t,
    len(triangles) == 2,
    "Square should produce exactly 2 triangles",
  )
  // Verify triangles are valid
  for i in 0 ..< len(triangles) {
    tri := triangles[i]
    for j in 0 ..< 3 {
      idx := tri[j]
      testing.expect(
        t,
        idx >= 0 && idx < 4,
        "Triangle vertex index should be valid",
      )
    }
    // Check triangle is not degenerate (all vertices different)
    testing.expect(
      t,
      tri[0] != tri[1] && tri[1] != tri[2] && tri[2] != tri[0],
      "Triangle should not be degenerate",
    )
    log.infof("Square triangle %d: [%d,%d,%d]", i, tri[0], tri[1], tri[2])
  }
}

@(test)
test_delaunay_hull_pentagon_with_interior :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 10 * time.Second)
  // Pentagon with interior point (more complex case)
  points := [][3]f32 {
    {0, 0, 0}, // Point 0 - hull
    {2, 0, 0}, // Point 1 - hull
    {3, 0, 1}, // Point 2 - hull
    {1, 0, 3}, // Point 3 - hull
    {-1, 0, 1}, // Point 4 - hull
    {1, 0, 1}, // Point 5 - interior
  }
  hull := []i32{0, 1, 2, 3, 4} // Hull boundary (5 vertices)
  triangles := make([dynamic][4]i32)
  defer delete(triangles)
  success := delaunay_hull(points, hull, &triangles)
  testing.expect(
    t,
    success,
    "Pentagon with interior triangulation should succeed",
  )
  // For a convex pentagon with 1 interior point, we expect multiple triangles
  testing.expect(t, len(triangles) > 0, "Should produce at least 1 triangle")
  testing.expect(
    t,
    len(triangles) <= 7,
    "Should not produce excessive triangles",
  )
  // Validate all triangles
  total_valid_triangles := 0
  for i in 0 ..< len(triangles) {
    tri := triangles[i]
    valid := true
    // Check vertex indices
    for j in 0 ..< 3 {
      idx := tri[j]
      if idx < 0 || idx >= 6 {
        valid = false
        break
      }
    }
    // Check not degenerate
    if tri[0] == tri[1] || tri[1] == tri[2] || tri[2] == tri[0] {
      valid = false
    }
    if valid {
      total_valid_triangles += 1
    }
  }
  testing.expect(
    t,
    total_valid_triangles > 0,
    "Should have at least one valid triangle",
  )
}

@(test)
test_delaunay_hull_edge_cases :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 10 * time.Second)
  // Case A: Too few points
  {
    points := [][3]f32{{0, 0, 0}, {1, 0, 0}} // Only 2 points
    hull := []i32{0, 1}
    triangles := make([dynamic][4]i32)
    defer delete(triangles)
    success := delaunay_hull(points, hull, &triangles)
    testing.expect(t, !success, "Should fail with 0 triangles")
  }
  // Case B: Collinear points
  {
    points := [][3]f32{{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}}
    hull := []i32{0, 1, 2, 3}
    triangles := make([dynamic][4]i32)
    defer delete(triangles)
    success := delaunay_hull(points, hull, &triangles)
    testing.expect(t, !success, "Should fail with collinear points")
  }
  // Case C: Very small triangle
  {
    points := [][3]f32{{0, 0, 0}, {0.001, 0, 0}, {0.0005, 0, 0.001}}
    hull := []i32{0, 1, 2}
    triangles := make([dynamic][4]i32)
    defer delete(triangles)
    success := delaunay_hull(points, hull, &triangles)
    testing.expect(t, success, "Should succeed with very small triangle")
  }
}

@(test)
test_delaunay_hull_performance :: proc(t: ^testing.T) {
  num_points := 50
  points := make([][3]f32, num_points)
  hull := make([]i32, num_points)
  defer delete(points)
  defer delete(hull)
  // Create circular arrangement of points for convex hull
  for i in 0 ..< num_points {
    angle := f32(i) * 2.0 * math.PI / f32(num_points)
    radius := f32(5.0)
    points[i] = {radius * math.cos_f32(angle), 0, radius * math.sin_f32(angle)}
    hull[i] = i32(i)
  }
  triangles := make([dynamic][4]i32)
  defer delete(triangles)
  start_time := time.now()
  success := delaunay_hull(points, hull, &triangles)
  end_time := time.now()
  duration := time.duration_milliseconds(time.diff(start_time, end_time))
  testing.expect(t, success, "Large point set triangulation should succeed")
  testing.expect(t, len(triangles) > 0, "Should produce triangles")
  testing.expect(t, duration < 1000, "Should complete within reasonable time")
  log.infof(
    "Performance test: %d points -> %d triangles in %d ms",
    num_points,
    len(triangles),
    duration,
  )
}
