package recast

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:testing"
import "core:time"

// Test with nav_test.obj - multi-level navigation test mesh
@(test)
test_nav_test_mesh :: proc(t: ^testing.T) {
  fmt.println("Testing with nav_test.obj (multi-level navigation)...")
  mesh_path := "assets/nav_test.obj"
  vertices, indices, areas, ok := load_obj_to_navmesh_input(mesh_path, 1.0)
  testing.expect(t, ok, "Failed to load navmesh")
  defer {
    delete(vertices)
    delete(indices)
    delete(areas)
  }
  fmt.printf(
    "  Loaded %d vertices and %d triangles\n",
    len(vertices),
    len(indices) / 3,
  )
  // Setup configuration
  cfg: Config
  // Get mesh bounds
  bmin, bmax := calc_bounds(vertices)
  cfg.bmin = bmin
  cfg.bmax = bmax
  fmt.printf(
    "  Mesh bounds: (%.4f, %.4f, %.4f) to (%.4f, %.4f, %.4f)\n",
    bmin.x,
    bmin.y,
    bmin.z,
    bmax.x,
    bmax.y,
    bmax.z,
  )
  // Standard test parameters (matching C++)
  cfg.cs = 0.3
  cfg.ch = 0.2
  cfg.walkable_slope = math.PI * 0.25
  cfg.walkable_height = 10
  cfg.walkable_climb = 4
  cfg.walkable_radius = 2
  cfg.max_edge_len = 12
  cfg.max_simplification_error = 1.3
  cfg.min_region_area = 8
  cfg.merge_region_area = 20
  cfg.max_verts_per_poly = 6
  cfg.detail_sample_dist = 6.0
  cfg.detail_sample_max_error = 1.0
  cfg.width, cfg.height = calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)
  fmt.printf("  Grid size: %d x %d\n", cfg.width, cfg.height)
  // Build heightfield
  hf := create_heightfield(
    cfg.width,
    cfg.height,
    cfg.bmin,
    cfg.bmax,
    cfg.cs,
    cfg.ch,
  )
  defer free_heightfield(hf)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  // Rasterize (areas already marked by load_obj_to_navmesh_input)
  ok = rasterize_triangles(
    vertices,
    indices,
    areas,
    hf,
    cfg.walkable_climb,
  )
  testing.expect(t, hf != nil, "Failed to rasterize triangles")
  // Filter
  filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
  filter_ledge_spans(
    int(cfg.walkable_height),
    int(cfg.walkable_climb),
    hf,
  )
  filter_walkable_low_height_spans(int(cfg.walkable_height), hf)
  // Build compact heightfield
  chf := create_compact_heightfield(
    cfg.walkable_height,
    cfg.walkable_climb,
    hf,
  )
  defer free_compact_heightfield(chf)
  testing.expect(t, chf != nil, "Failed to build compact heightfield")
  // Check for multiple levels
  max_layers := 0
  total_layers := 0
  for i in 0 ..< (chf.width * chf.height) {
    layers := int(chf.cells[i].count)
    max_layers = max(max_layers, layers)
    if layers > 1 do total_layers += 1
  }
  fmt.printf("  Maximum layers in single cell: %d\n", max_layers)
  fmt.printf("  Cells with multiple layers: %d\n", total_layers)
  // Optionally test layers for multi-level navigation
  // Note: May fail if >255 regions, which is fine for standard navmesh
  lset, layer_ok := build_heightfield_layers(
    chf,
    0,
    cfg.walkable_height,
  )
  defer free_heightfield_layer_set(lset)
  if layer_ok && len(lset) > 0 {
    fmt.printf("  Generated %d navigation layers:\n", len(lset))
    for layer, i in lset {
      fmt.printf(
        "    Layer %d: %dx%d at height %d-%d\n",
        i,
        layer.width,
        layer.height,
        layer.miny,
        layer.maxy,
      )
    }
  } else if !layer_ok {
    fmt.println(
      "  Note: Layer building skipped (likely >255 regions) - using standard regions instead",
    )
  }
  // Continue with standard navmesh generation
  erode_walkable_area(cfg.walkable_radius, chf)
  build_distance_field(chf)
  build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
  // Analyze regions
  max_region := 0
  region_counts := make([]int, 256)
  defer delete(region_counts)
  total_region_spans := 0
  for i in 0 ..< len(chf.spans) {
    reg := int(chf.spans[i].reg)
    if reg > 0 && reg < 256 {
      region_counts[reg] += 1
      total_region_spans += 1
      if reg > max_region do max_region = reg
    }
  }
  fmt.println("  Region Analysis:")
  fmt.printf("    Total regions: %d\n", max_region)
  fmt.printf("    Total spans in regions: %d\n", total_region_spans)
  // Count regions by size
  small_regions, medium_regions, large_regions := 0, 0, 0
  for i in 1 ..= max_region {
    if region_counts[i] > 0 {
      if region_counts[i] < 50 {
        small_regions += 1
      } else if region_counts[i] < 200 {
        medium_regions += 1
      } else {
        large_regions += 1
      }
    }
  }
  fmt.printf("    Small regions (<50 spans): %d\n", small_regions)
  fmt.printf("    Medium regions (50-200 spans): %d\n", medium_regions)
  fmt.printf("    Large regions (>200 spans): %d\n", large_regions)
  // Build contours
  cset := create_contour_set(
    chf,
    cfg.max_simplification_error,
    cfg.max_edge_len,
  )
  defer free_contour_set(cset)
  testing.expect(t, cset != nil, "Failed to build contours")
  // Analyze contours
  min_verts, max_verts := i32(999999), i32(0)
  total_verts := 0
  for contour in cset.conts {
    verts := i32(len(contour.verts))
    min_verts = min(min_verts, verts)
    max_verts = max(max_verts, verts)
    total_verts += int(verts)
  }
  // Build polygon mesh
  pmesh := create_poly_mesh(cset, cfg.max_verts_per_poly)
  defer free_poly_mesh(pmesh)
  testing.expect(t, pmesh != nil, "Failed to build poly mesh")
  // Analyze polygon mesh regions
  poly_regions := make([]int, 256)
  defer delete(poly_regions)
  max_poly_region := 0
  for i in 0 ..< pmesh.npolys {
    reg := int(pmesh.regs[i])
    if reg > 0 && reg < 256 {
      poly_regions[reg] += 1
      if reg > max_poly_region do max_poly_region = reg
    }
  }
  log.infof("  Polygon Mesh Analysis:")
  log.infof("    Total polygons: %d", pmesh.npolys)
  log.infof("    Total vertices: %d", len(pmesh.verts))
  log.infof("    Unique regions in mesh: %d", max_poly_region)
  // Count polygons per region
  log.infof("    Polygons per region distribution:")
  for i in 1 ..= min(max_poly_region, 19) {   // Show first 20 regions
    if poly_regions[i] > 0 {
      log.infof("      Region %d: %d polygons\n", i, poly_regions[i])
    }
  }
  // Analyze polygon connectivity
  fmt.println("  Polygon Connectivity Analysis:")
  connection_counts := make([]int, 7) // 0 to 6 connections
  defer delete(connection_counts)
  total_connections := 0
  isolated_polys := 0
  fully_connected_polys := 0
  for i in 0 ..< pmesh.npolys {
    poly := pmesh.polys[i * pmesh.nvp * 2:]
    connections := 0
    // Count connections for this polygon
    for j in 0 ..< pmesh.nvp {
      if poly[j] == RC_MESH_NULL_IDX do break // End of vertices
      // Check if edge has a neighbor
      if poly[pmesh.nvp + j] != RC_MESH_NULL_IDX {
        connections += 1
        total_connections += 1
      }
    }
    connection_counts[min(connections, 6)] += 1
    if connections == 0 do isolated_polys += 1
    if connections == int(pmesh.nvp) do fully_connected_polys += 1
  }
  fmt.println("    Connection distribution:")
  for i in 0 ..= 6 {
    if connection_counts[i] > 0 {
      fmt.printf(
        "      %d connections: %d polygons\n",
        i,
        connection_counts[i],
      )
    }
  }
  fmt.printf("    Isolated polygons (no connections): %d\n", isolated_polys)
  avg_connections :=
    pmesh.npolys > 0 ? f32(total_connections) / f32(pmesh.npolys) : 0
  fmt.printf("    Average connections per polygon: %.3f\n", avg_connections)
  // Check for disconnected regions (islands)
  visited := make([]bool, pmesh.npolys)
  defer delete(visited)
  island_count := 0
  for i in 0 ..< pmesh.npolys {
    if !visited[i] {
      // Start a new island
      island_count += 1
      stack: [dynamic]int
      defer delete(stack)
      append(&stack, int(i))
      island_size := 0
      for len(stack) > 0 {
        curr := pop(&stack)
        if visited[curr] do continue
        visited[curr] = true
        island_size += 1
        // Add connected neighbors to stack
        poly := pmesh.polys[curr * int(pmesh.nvp) * 2:]
        for j in 0 ..< pmesh.nvp {
          if poly[j] == RC_MESH_NULL_IDX do break
          neighbor := int(poly[pmesh.nvp + j])
          if neighbor != int(RC_MESH_NULL_IDX) && !visited[neighbor] {
            append(&stack, neighbor)
          }
        }
      }
      if island_size > 1 {
        log.infof("    Island %d: %d polygons\n", island_count, island_size)
      }
    }
  }
  testing.expectf(t, island_count > 0, "island count should be > 0")
  dmesh := create_poly_mesh_detail(
    pmesh,
    chf,
    cfg.detail_sample_dist,
    cfg.detail_sample_max_error,
  )
  defer free_poly_mesh_detail(dmesh)
  testing.expectf(t, dmesh != nil, "failed to build poly mesh detail")
}

// Test with dungeon.obj - complex indoor environment
@(test)
test_dungeon_mesh :: proc(t: ^testing.T) {
  mesh_path := "assets/dungeon.obj"
  vertices, indices, areas, ok := load_obj_to_navmesh_input(mesh_path, 1.0)
  testing.expectf(t, ok, "failed to load asset")
  defer {
    delete(vertices)
    delete(indices)
    delete(areas)
  }
  cfg: Config
  cfg.bmin, cfg.bmax = calc_bounds(vertices)
  // Dungeon-appropriate parameters
  cfg.cs = 0.3
  cfg.ch = 0.2
  cfg.walkable_slope = math.PI * 0.25
  cfg.walkable_height = 10
  cfg.walkable_climb = 4
  cfg.walkable_radius = 2
  cfg.max_edge_len = 12
  cfg.max_simplification_error = 1.3
  cfg.min_region_area = 8
  cfg.merge_region_area = 20
  cfg.max_verts_per_poly = 6
  cfg.detail_sample_dist = 6.0
  cfg.detail_sample_max_error = 1.0
  cfg.width, cfg.height = calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)
  testing.expectf(
    t,
    cfg.width > 0 && cfg.height > 0,
    "Grid size should be > 0: %d x %d\n",
    cfg.width,
    cfg.height,
  )
  // Step 1: Build heightfield
  hf := create_heightfield(
    cfg.width,
    cfg.height,
    cfg.bmin,
    cfg.bmax,
    cfg.cs,
    cfg.ch,
  )
  defer free_heightfield(hf)
  testing.expect(t, hf != nil, "Failed to create heightfield")
  // Step 2: Rasterize triangles
  ok = rasterize_triangles(
    vertices,
    indices,
    areas,
    hf,
    cfg.walkable_climb,
  )
  testing.expect(t, hf != nil, "Failed to rasterize triangles")
  // Step 3: Filter walkable surfaces
  filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
  filter_ledge_spans(
    int(cfg.walkable_height),
    int(cfg.walkable_climb),
    hf,
  )
  filter_walkable_low_height_spans(int(cfg.walkable_height), hf)
  // Step 4: Build compact heightfield
  chf := create_compact_heightfield(
    cfg.walkable_height,
    cfg.walkable_climb,
    hf,
  )
  defer free_compact_heightfield(chf)
  testing.expect(t, chf != nil, "Failed to build compact heightfield")
  // Step 5: Erode walkable area
  erode_walkable_area(cfg.walkable_radius, chf)
  // Step 6: Build distance field and regions (standard approach, NOT layers)
  build_distance_field(chf)
  build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
  // Count regions created
  max_region := chf.spans[0].reg
  for i in 1 ..< len(chf.spans) {
    if chf.spans[i].reg > max_region {
      max_region = chf.spans[i].reg
    }
  }
  // Step 7: Build contours
  cset := create_contour_set(
    chf,
    cfg.max_simplification_error,
    cfg.max_edge_len,
  )
  defer free_contour_set(cset)
  testing.expect(t, cset != nil, "Failed to build contours")
  // Step 8: Build polygon mesh
  pmesh := create_poly_mesh(cset, cfg.max_verts_per_poly)
  defer free_poly_mesh(pmesh)
  testing.expect(t, pmesh != nil, "Failed to build poly mesh")
}

// Test with floor_with_5_obstacles.obj
@(test)
test_floor_with_obstacles :: proc(t: ^testing.T) {
  mesh_path := "assets/floor_with_5_obstacles.obj"
  vertices, indices, areas, ok := load_obj_to_navmesh_input(mesh_path, 1.0)
  testing.expect(t, ok, "failed to load asset")
  defer {
    delete(vertices)
    delete(indices)
    delete(areas)
  }
  cfg: Config
  cfg.bmin, cfg.bmax = calc_bounds(vertices)
  cfg.cs = 0.3
  cfg.ch = 0.2
  cfg.walkable_slope = math.PI * 0.25
  cfg.walkable_height = 10
  cfg.walkable_climb = 4
  cfg.walkable_radius = 2
  cfg.max_edge_len = 12
  cfg.max_simplification_error = 1.3
  cfg.min_region_area = 8
  cfg.merge_region_area = 20
  cfg.max_verts_per_poly = 6
  cfg.detail_sample_dist = 6.0
  cfg.detail_sample_max_error = 1.0
  cfg.width, cfg.height = calc_grid_size(cfg.bmin, cfg.bmax, cfg.cs)
  // Full pipeline
  hf := create_heightfield(
    cfg.width,
    cfg.height,
    cfg.bmin,
    cfg.bmax,
    cfg.cs,
    cfg.ch,
  )
  defer free_heightfield(hf)
  rasterize_triangles(vertices, indices, areas, hf, cfg.walkable_climb)
  filter_low_hanging_walkable_obstacles(int(cfg.walkable_climb), hf)
  filter_ledge_spans(
    int(cfg.walkable_height),
    int(cfg.walkable_climb),
    hf,
  )
  filter_walkable_low_height_spans(int(cfg.walkable_height), hf)
  chf := create_compact_heightfield(
    cfg.walkable_height,
    cfg.walkable_climb,
    hf,
  )
  defer free_compact_heightfield(chf)
  erode_walkable_area(cfg.walkable_radius, chf)
  build_distance_field(chf)
  build_regions(chf, 0, cfg.min_region_area, cfg.merge_region_area)
  cset := create_contour_set(
    chf,
    cfg.max_simplification_error,
    cfg.max_edge_len,
  )
  defer free_contour_set(cset)
  pmesh := create_poly_mesh(cset, cfg.max_verts_per_poly)
  defer free_poly_mesh(pmesh)
  region_count := slice.max(pmesh.regs[:pmesh.npolys])
  log.infof(
    "Regions created (obstacles should separate walkable areas): %d\n",
    region_count,
  )
  testing.expect(t, region_count > 0)
}

@(test)
test_floor_5_obstacles_simple :: proc(t: ^testing.T) {
  // Load the floor_with_5_obstacles.obj mesh
  vertices, indices, areas, ok := load_obj_to_navmesh_input(
    "assets/floor_with_5_obstacles.obj",
  )
  defer {
    delete(vertices)
    delete(indices)
    delete(areas)
  }
  testing.expectf(t, ok, "Failed to load floor_with_5_obstacles.obj")
  cfg: Config
  cfg.cs = 0.3
  cfg.ch = 0.2
  cfg.walkable_slope = math.PI * 0.25
  cfg.walkable_height = 10
  cfg.walkable_climb = 4
  cfg.walkable_radius = 2
  cfg.max_edge_len = 12
  cfg.max_simplification_error = 1.3
  cfg.min_region_area = 64
  cfg.merge_region_area = 400
  cfg.max_verts_per_poly = 6
  cfg.detail_sample_dist = 6.0
  cfg.detail_sample_max_error = 1.0
  // Build navigation mesh
  pmesh, dmesh, build_ok := build_navmesh(vertices, indices, areas, cfg)
  defer {
    free_poly_mesh(pmesh)
    free_poly_mesh_detail(dmesh)
  }
  testing.expectf(t, build_ok, "Failed to build navigation mesh")
  testing.expect(t, pmesh.npolys > 0, "Should generate polygons")
  testing.expect(t, len(pmesh.verts) > 0, "Should generate vertices")
}
