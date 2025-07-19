package navigation

import "base:intrinsics"
import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import linalg "core:math/linalg"
import "../geometry"

// Import types from recast/detour files
// Area types are now simple u8 values matching Recast

NOT_CONNECTED :: 0b111111  // All 6 bits set - no valid connection

// Config is now Config from recast_types.odin
// Use default_config() to get default configuration

DEFAULT_CONFIG :: Config{
    width = 0,  // Will be calculated from bounds
    height = 0, // Will be calculated from bounds
    tile_size = 0, // No tiling by default
    border_size = 0,
    cs = 0.3,
    ch = 0.2,
    bmin = {},  // Will be set from input
    bmax = {},  // Will be set from input
    walkable_slope_angle = 45.0,  // degrees
    walkable_height = 3,    // 0.5m at 0.2 ch = 2.5 cells, round to 3
    walkable_climb = 1,     // 0.1m at 0.2 ch = 0.5 cells, round to 1
    walkable_radius = 0,    // 0.05m at 0.3 cs = 0.16 cells, round to 0
    max_edge_len = 40,       // 12m at 0.3 cs = 40 cells
    max_simplification_error = 1.3,
    min_region_area = 1,
    merge_region_area = 20,
    max_verts_per_poly = 6,
    detail_sample_dist = 6.0,
    detail_sample_max_error = 1.0,
  }

Input :: struct {
  vertices: [][3]f32,     // Vertex positions
  indices:  []u32,        // Triangle indices (3 per triangle)
  areas:    []u8,         // Area types per triangle (len(areas) == len(indices)/3)
}

// Input mesh for navigation building
NavMeshInput :: struct {
  vertices: [][3]f32,
  indices:  []u32,
  areas:    []u8,
}

// Navigation mesh structures moved to detour_types.odin
// Use NavMesh, Poly, PolyDetail instead

// Destroy function for resource cleanup
destroy :: proc(navmesh: ^NavMesh) {
  log.debug("Destroying NavMesh")

  // Clean up all tiles
  for &tile in navmesh.tiles {
    if tile.header != nil {
      free(tile.header)
      tile.header = nil
    }

    if len(tile.verts) > 0 {
      delete(tile.verts)
      tile.verts = nil
    }

    if len(tile.polys) > 0 {
      delete(tile.polys)
      tile.polys = nil
    }

    if len(tile.links) > 0 {
      delete(tile.links)
      tile.links = nil
    }

    if len(tile.detail_meshes) > 0 {
      delete(tile.detail_meshes)
      tile.detail_meshes = nil
    }

    if len(tile.detail_verts) > 0 {
      delete(tile.detail_verts)
      tile.detail_verts = nil
    }

    if len(tile.detail_tris) > 0 {
      delete(tile.detail_tris)
      tile.detail_tris = nil
    }

    if len(tile.bv_tree) > 0 {
      delete(tile.bv_tree)
      tile.bv_tree = nil
    }

    if len(tile.off_mesh_cons) > 0 {
      delete(tile.off_mesh_cons)
      tile.off_mesh_cons = nil
    }

    if len(tile.data) > 0 {
      delete(tile.data)
      tile.data = nil
    }
  }

  // Clean up tiles array
  if len(navmesh.tiles) > 0 {
    delete(navmesh.tiles)
    navmesh.tiles = nil
  }

  // Clean up position lookup array
  if len(navmesh.pos_lookup) > 0 {
    delete(navmesh.pos_lookup)
    navmesh.pos_lookup = nil
  }
}

// Builder state for navmesh construction
NavMeshBuilder :: struct {
  config: Config,  // Recast configuration
  // Debug data storage - these will be freed when builder is destroyed
  debug_heightfield: ^Heightfield,
  debug_compact_hf: ^CompactHeightfield,
  debug_contours: ^ContourSet,
  debug_poly_mesh: ^PolyMesh,
}

// Build navigation mesh using Recast/Detour pipeline
build :: proc(builder: ^NavMeshBuilder, input: ^Input) -> (NavMesh, bool) {
  if len(input.vertices) == 0 {
    log.error("No vertices provided for navigation mesh")
    return NavMesh{}, false
  }

  // Validate indices
  if len(input.indices) % 3 != 0 {
    log.error("Index count must be multiple of 3 for triangles")
    return NavMesh{}, false
  }

  triangle_count := len(input.indices) / 3

  // Validate areas array matches triangle count exactly (strict validation)
  if len(input.areas) != triangle_count && len(input.areas) != 0 {
    log.warn("Area count (%d) must match triangle count (%d) or be empty", len(input.areas), triangle_count)
    return NavMesh{}, false
  }

  log.infof("Building navigation mesh with %d vertices, %d triangles", len(input.vertices), triangle_count)
  
  // Debug: Log area distribution
  area_counts: map[u8]int
  defer delete(area_counts)
  for area in input.areas {
    area_counts[area] = area_counts[area] + 1
  }
  for area, count in area_counts {
    log.infof("  Area %d: %d triangles", area, count)
  }
  
  // Debug: Check input.indices before processing
  log.debugf("input.indices[0:15] in navigation: %v", input.indices[0:min(15, len(input.indices))])
  
  // Debug: Check index bounds
  max_index := u32(0)
  for idx in input.indices {
    if idx > max_index {
      max_index = idx
    }
  }
  log.infof("Max vertex index in triangles: %d (vertices available: %d)", max_index, len(input.vertices)-1)

  // Calculate bounds
  bmin := input.vertices[0]
  bmax := input.vertices[0]
  for vertex in input.vertices[1:] {
    bmin = linalg.min(bmin, vertex)
    bmax = linalg.max(bmax, vertex)
  }

  // Update config bounds
  builder.config.bmin = bmin
  builder.config.bmax = bmax

  // Calculate grid size
  builder.config.width = i32((bmax.x - bmin.x) / builder.config.cs) + 1
  builder.config.height = i32((bmax.z - bmin.z) / builder.config.cs) + 1
  
  config := builder.config

  log.infof("Grid size: %dx%d", config.width, config.height)
  log.infof("Bounds: [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f]", bmin.x, bmin.y, bmin.z, bmax.x, bmax.y, bmax.z)

  // Try to use voxelization pipeline to properly handle obstacles
  if navmesh, ok := build_with_heightfield(builder, input); ok {
    return navmesh, true
  }

  // Fallback to simple implementation
  log.warn("Using simple navigation mesh building (no obstacle detection)")

  navmesh := NavMesh{
    max_tiles = 1,
    tile_width = f32(config.width),
    tile_height = f32(config.height),
    tiles = make([]MeshTile, 1),
  }

  // Create a single tile
  tile := &navmesh.tiles[0]
  tile.salt = 1  // Initialize salt to non-zero value (required for valid PolyRef)
  tile.header = new(MeshHeader)
  tile.header.magic = NAVMESH_MAGIC
  tile.header.version = NAVMESH_VERSION
  tile.header.poly_count = i32(len(input.indices) / 3)
  tile.header.vert_count = i32(len(input.vertices))
  tile.header.max_link_count = 0
  tile.header.bmin = bmin
  tile.header.bmax = bmax
  tile.header.walkable_height = f32(config.walkable_height)
  tile.header.walkable_radius = f32(config.walkable_radius)
  tile.header.walkable_climb = f32(config.walkable_climb)

  // Copy vertices
  tile.verts = make([]f32, len(input.vertices) * 3)
  for vertex, i in input.vertices {
    tile.verts[i*3 + 0] = vertex.x
    tile.verts[i*3 + 1] = vertex.y
    tile.verts[i*3 + 2] = vertex.z
  }

  // Create polygons from triangles
  tile.polys = make([]Poly, len(input.indices) / 3)
  for i in 0..<len(input.indices)/3 {
    poly := &tile.polys[i]
    poly.vert_count = 3
    poly.verts[0] = u16(input.indices[i*3 + 0])
    poly.verts[1] = u16(input.indices[i*3 + 1])
    poly.verts[2] = u16(input.indices[i*3 + 2])
    poly.flags = 1 // Walkable
    area := input.areas[i] if i < len(input.areas) else u8(WALKABLE_AREA)
    set_poly_area(poly, area)

    // Initialize neighbor links to no connection
    for j in 0..<3 {
      poly.neis[j] = NOT_CONNECTED
    }
  }

  log.infof("Created navigation mesh with %d polygons", len(tile.polys))
  return navmesh, true
}

// Builder init/destroy compatibility functions
builder_init :: proc(config: Config) -> NavMeshBuilder {
  return NavMeshBuilder{
    config = config,
    // Initialize other fields as needed
  }
}

builder_destroy :: proc(builder: ^NavMeshBuilder) {
  // Cleanup debug resources if they exist
  if builder.debug_heightfield != nil {
    free_height_field(builder.debug_heightfield)
    builder.debug_heightfield = nil
  }
  if builder.debug_compact_hf != nil {
    free_compact_heightfield(builder.debug_compact_hf)
    builder.debug_compact_hf = nil
  }
  if builder.debug_contours != nil {
    free_contour_set(builder.debug_contours)
    builder.debug_contours = nil
  }
  if builder.debug_poly_mesh != nil {
    free_poly_mesh(builder.debug_poly_mesh)
    builder.debug_poly_mesh = nil
  }
}

// Build navigation mesh using heightfield voxelization to handle obstacles
build_with_heightfield :: proc(builder: ^NavMeshBuilder, input: ^Input) -> (NavMesh, bool) {
  config := builder.config

  // Step 1: Create heightfield
  log.debugf("Creating heightfield: %dx%d, bounds [%.2f,%.2f,%.2f] to [%.2f,%.2f,%.2f], cs=%.2f ch=%.2f",
    config.width, config.height, config.bmin.x, config.bmin.y, config.bmin.z, 
    config.bmax.x, config.bmax.y, config.bmax.z, config.cs, config.ch)
  hf := create_height_field(config.width, config.height, config.bmin, config.bmax, config.cs, config.ch)
  if hf == nil {
    log.error("Failed to create heightfield")
    return NavMesh{}, false
  }
  // Note: Don't defer free_height_field(hf) - we'll store it for visualization

  // Convert input data to format expected by rasterize_triangles
  verts := make([]f32, len(input.vertices) * 3)
  defer delete(verts)
  for v, i in input.vertices {
    verts[i*3 + 0] = v.x
    verts[i*3 + 1] = v.y
    verts[i*3 + 2] = v.z
  }

  tris := make([]i32, len(input.indices))
  defer delete(tris)
  
  // Manual loop to debug iteration issue
  for i in 0..<len(input.indices) {
    tris[i] = i32(input.indices[i])
    if i < 15 {
      log.debugf("Manual: tris[%d] = %d (input.indices[%d] = %d)", i, tris[i], i, input.indices[i])
    }
  }

  // Step 2: Rasterize all triangles into heightfield
  // This creates a voxel representation where obstacles (NULL_AREA) create holes
  log.info("Rasterizing triangles into heightfield...")
  rasterize_triangles(hf, verts, tris, input.areas, len(input.indices)/3)

  // Step 3: Filter walkable surfaces
  log.info("Filtering walkable surfaces...")

  // Count walkable and non-walkable spans before filtering
  walkable_before := 0
  null_before := 0
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width
      s := hf.spans[idx]
      for s != nil {
        if s.area == WALKABLE_AREA {
          walkable_before += 1
        } else if s.area == NULL_AREA {
          null_before += 1
        }
        s = s.next
      }
    }
  }
  log.infof("Before filtering: %d walkable spans, %d null spans", walkable_before, null_before)

  // Apply filters to mark obstacles and ledges properly
  filter_lowHanging_walkable_obstacles(config.walkable_climb, hf)
  filter_ledge_spans(config.walkable_height, config.walkable_climb, hf)
  filter_walkable_low_height_spans(config.walkable_height, hf)

  // Count after filtering
  walkable_after := 0
  null_after := 0
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width
      s := hf.spans[idx]
      for s != nil {
        if s.area == WALKABLE_AREA {
          walkable_after += 1
        } else if s.area == NULL_AREA {
          null_after += 1
        }
        s = s.next
      }
    }
  }
  log.infof("After filtering: %d walkable spans, %d null spans", walkable_after, null_after)
  
  // Debug: Check if any areas have NULL spans that should create holes
  holes_count := 0
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width
      s := hf.spans[idx]
      has_null := false
      has_walkable := false
      
      for s != nil {
        if s.area == NULL_AREA do has_null = true
        if s.area == WALKABLE_AREA do has_walkable = true
        s = s.next
      }
      
      // Count cells that have NULL area but no walkable area (true holes)
      if has_null && !has_walkable {
        holes_count += 1
      }
    }
  }
  log.infof("Cells with holes (NULL area only): %d out of %d total cells", holes_count, hf.width * hf.height)
  
  // Debug: Check heightfield values at specific locations
  log.info("Checking heightfield values at key locations:")
  
  // Center of scene (near obstacles)
  cx, cz := hf.width/2, hf.height/2
  center_idx := cx + cz * hf.width
  log.infof("Center (%d,%d) - grid coords, world (%.1f, %.1f):", 
    cx, cz, hf.bmin.x + f32(cx)*hf.cs, hf.bmin.z + f32(cz)*hf.cs)
  
  span_count := 0
  for s := hf.spans[center_idx]; s != nil; s = s.next {
    world_ymin := hf.bmin.y + f32(s.smin) * hf.ch
    world_ymax := hf.bmin.y + f32(s.smax) * hf.ch
    log.infof("  Span %d: height %d-%d (world %.2f-%.2f), area %d", 
      span_count, s.smin, s.smax, world_ymin, world_ymax, s.area)
    span_count += 1
  }
  
  // Corner of scene (no obstacles)
  corner_idx := 0 // (0,0)
  log.infof("Corner (0,0) - world (%.1f, %.1f):", hf.bmin.x, hf.bmin.z)
  span_count = 0
  for s := hf.spans[corner_idx]; s != nil; s = s.next {
    world_ymin := hf.bmin.y + f32(s.smin) * hf.ch
    world_ymax := hf.bmin.y + f32(s.smax) * hf.ch
    log.infof("  Span %d: height %d-%d (world %.2f-%.2f), area %d", 
      span_count, s.smin, s.smax, world_ymin, world_ymax, s.area)
    span_count += 1
  }
  
  // Check a few more positions
  positions := [][2]i32{
    {5, 5},   // Near corner but not edge
    {15, 15}, // Mid-way to center  
    {25, 25}, // Near corner on opposite side
  }
  
  for pos in positions {
    idx := pos.x + pos.y * hf.width
    if idx >= 0 && idx < i32(len(hf.spans)) {
      world_x := hf.bmin.x + f32(pos.x) * hf.cs
      world_z := hf.bmin.z + f32(pos.y) * hf.cs
      span_count := 0
      for s := hf.spans[idx]; s != nil; s = s.next {
        span_count += 1
      }
      log.infof("Position (%d,%d) world (%.1f,%.1f): %d spans", 
        pos.x, pos.y, world_x, world_z, span_count)
    }
  }

  // Step 4: Build compact heightfield
  chf := alloc_compact_heightfield()
  if chf == nil {
    log.error("Failed to allocate compact heightfield")
    free_height_field(hf)
    return NavMesh{}, false
  }
  // Note: Don't defer free_compact_heightfield(chf) - we'll store it for visualization

  if !build_compact_heightfield(config.walkable_height, config.walkable_climb, hf, chf) {
    log.error("Failed to build compact heightfield")
    return NavMesh{}, false
  }
  
  // Debug: Check compact heightfield values
  log.info("Checking compact heightfield values:")
  log.infof("Compact HF: width=%d, height=%d, spanCount=%d", chf.width, chf.height, chf.span_count)
  
  // Check center cell
  chf_cx, chf_cz := chf.width/2, chf.height/2
  chf_cidx := chf_cx + chf_cz * chf.width
  center_cell := &chf.cells[chf_cidx]
  index, count := unpack_compact_cell(center_cell.index)
  log.infof("Center (%d,%d) - index=%d, count=%d", chf_cx, chf_cz, index, count)
  
  for i in 0..<count {
    span_idx := i32(index) + i32(i)
    s := &chf.spans[span_idx]
    // Height is packed in upper 8 bits of con
    height := (s.con >> 24) & 0xFF
    log.infof("  Span %d: y=%d, h=%d, con=%x, reg=%d, area=%d", 
      i, s.y, height, s.con & 0xFFFFFF, s.reg, chf.areas[span_idx])
    
    // Check connections
    for dir in 0..<4 {
      con_val := get_con(s, dir)
      if con_val != NOT_CONNECTED {
        log.infof("    Dir %d: connected to span offset %d", dir, con_val)
      }
    }
  }
  
  // Check corner cell  
  chf_corner_idx := 0
  chf_corner_cell := &chf.cells[chf_corner_idx]
  corner_index, corner_count := unpack_compact_cell(chf_corner_cell.index)
  log.infof("Corner (0,0) - index=%d, count=%d", corner_index, corner_count)
  
  for i in 0..<corner_count {
    span_idx := i32(corner_index) + i32(i)
    s := &chf.spans[span_idx]
    height := (s.con >> 24) & 0xFF
    log.infof("  Span %d: y=%d, h=%d, area=%d", i, s.y, height, chf.areas[span_idx])
  }
  
  // Check debug obstacle positions
  debug_positions := []struct{pos: [2]f32, name: string}{
    {{0, 0}, "Center"},
    {{5, 5}, "Northeast"},
    {{-5, -5}, "Southwest"}, 
    {{10, 0}, "East edge"},
    {{0, -10}, "South edge"},
  }
  
  log.info("Checking cells at debug obstacle positions:")
  for debug_pos in debug_positions {
    // Convert world position to cell coordinates
    cell_x := i32((debug_pos.pos.x - chf.bmin.x) / chf.cs)
    cell_z := i32((debug_pos.pos.y - chf.bmin.z) / chf.cs)
    
    if cell_x >= 0 && cell_x < chf.width && cell_z >= 0 && cell_z < chf.height {
      cell_idx := cell_x + cell_z * chf.width
      cell := &chf.cells[cell_idx]
      cell_index, cell_count := unpack_compact_cell(cell.index)
      log.infof("  %s: world (%.1f,%.1f) -> cell (%d,%d): count=%d", 
        debug_pos.name, debug_pos.pos.x, debug_pos.pos.y, cell_x, cell_z, cell_count)
        
      // If there are spans, show their details
      if cell_count > 0 {
        for i in 0..<cell_count {
          span_idx := i32(cell_index) + i32(i)
          s := &chf.spans[span_idx]
          height := (s.con >> 24) & 0xFF
          log.infof("    Span %d: y=%d, h=%d, area=%d", i, s.y, height, chf.areas[span_idx])
        }
      }
    }
  }
  
  // Check cells that should be walkable
  walkable_positions := []struct{pos: [2]f32, name: string}{
    {{2, 2}, "Near center"},      // Between center and NE obstacles
    {{-2, -2}, "Near SW"},        // Between center and SW obstacles
    {{7, 0}, "Between center/east"},  // Between center and east edge
    {{0, 5}, "North of center"},   // Clear area north
    {{-10, 10}, "NW corner"},     // Far corner, should be clear
    {{12, 12}, "NE far"},         // Far northeast
  }
  
  log.info("Checking cells that should be walkable:")
  walkable_count := 0
  for test_pos in walkable_positions {
    // Convert world position to cell coordinates
    cell_x := i32((test_pos.pos.x - chf.bmin.x) / chf.cs)
    cell_z := i32((test_pos.pos.y - chf.bmin.z) / chf.cs)
    
    if cell_x >= 0 && cell_x < chf.width && cell_z >= 0 && cell_z < chf.height {
      cell_idx := cell_x + cell_z * chf.width
      cell := &chf.cells[cell_idx]
      cell_index, cell_count := unpack_compact_cell(cell.index)
      log.infof("  %s: world (%.1f,%.1f) -> cell (%d,%d): count=%d", 
        test_pos.name, test_pos.pos.x, test_pos.pos.y, cell_x, cell_z, cell_count)
        
      if cell_count > 0 {
        walkable_count += 1
        for i in 0..<min(cell_count, 2) { // Show first 2 spans
          span_idx := i32(cell_index) + i32(i)
          s := &chf.spans[span_idx]
          height := (s.con >> 24) & 0xFF
          log.infof("    Span %d: y=%d, h=%d, area=%d", i, s.y, height, chf.areas[span_idx])
        }
      }
    }
  }
  log.infof("Found %d/%d walkable test positions", walkable_count, len(walkable_positions))
  
  // Count total cells with/without spans and find blocked cells
  cells_with_spans := 0
  cells_without_spans := 0
  blocked_cells := make([dynamic][2]i32)
  defer delete(blocked_cells)
  
  for z in 0..<chf.height {
    for x in 0..<chf.width {
      idx := x + z * chf.width
      _, count := unpack_compact_cell(chf.cells[idx].index)
      if count > 0 {
        cells_with_spans += 1
      } else {
        cells_without_spans += 1
        append(&blocked_cells, [2]i32{x, z})
      }
    }
  }
  
  log.infof("Cell statistics: %d with spans (walkable), %d without spans (blocked)", 
    cells_with_spans, cells_without_spans)
  log.infof("Total cells: %d (%.1f%% walkable)", 
    cells_with_spans + cells_without_spans, 
    f32(cells_with_spans) * 100.0 / f32(cells_with_spans + cells_without_spans))
    
  // Show blocked cell positions
  log.info("Blocked cells:")
  for blocked_cell, i in blocked_cells {
    world_x := chf.bmin.x + f32(blocked_cell.x) * chf.cs
    world_z := chf.bmin.z + f32(blocked_cell.y) * chf.cs
    if i < 10 || i >= len(blocked_cells) - 2 { // Show first 10 and last 2
      log.infof("  Cell (%d,%d) -> world (%.1f,%.1f)", 
        blocked_cell.x, blocked_cell.y, world_x, world_z)
    } else if i == 10 {
      log.infof("  ... %d more cells ...", len(blocked_cells) - 12)
    }
  }
  
  // Check connectivity correctness
  log.info("Checking connectivity correctness:")
  
  // Test specific cells that should be connected
  connectivity_tests := []struct{cell: [2]i32, name: string}{
    {{15, 16}, "North of center"},      // Should connect to (15,17) north
    {{16, 15}, "East of center"},       // Should connect to (17,15) east  
    {{14, 15}, "West of center"},       // Should connect to (13,15) west
    {{15, 14}, "South of center"},      // Should connect to (15,13) south
    {{1, 1}, "Near corner"},            // Should have 2 connections (corner)
    {{15, 1}, "Edge cell"},             // Should have 3 connections (edge)
  }
  
  for test in connectivity_tests {
    cell_idx := test.cell.x + test.cell.y * chf.width
    if cell_idx >= 0 && cell_idx < i32(len(chf.cells)) {
      cell := &chf.cells[cell_idx]
      cell_index, cell_count := unpack_compact_cell(cell.index)
      
      if cell_count > 0 {
        span_idx := i32(cell_index)
        s := &chf.spans[span_idx]
        
        // Check all 4 directions
        connections := 0
        connected_dirs := make([dynamic]string)
        defer delete(connected_dirs)
        
        dir_names := []string{"West", "North", "East", "South"}  
        dir_offsets := [][2]i32{{-1,0}, {0,1}, {1,0}, {0,-1}}
        
        for dir in 0..<4 {
          con_val := get_con(s, dir)
          if con_val != NOT_CONNECTED {
            connections += 1
            
            // Verify the connection points to a valid neighbor
            nx := test.cell.x + dir_offsets[dir].x
            ny := test.cell.y + dir_offsets[dir].y
            
            if nx >= 0 && nx < chf.width && ny >= 0 && ny < chf.height {
              neighbor_idx := nx + ny * chf.width
              neighbor_cell := &chf.cells[neighbor_idx]
              n_index, n_count := unpack_compact_cell(neighbor_cell.index)
              
              if n_count > 0 {
                // Connection should point to valid span in neighbor
                expected_span_idx := i32(n_index) + i32(con_val)
                if expected_span_idx < i32(n_index) + i32(n_count) {
                  append(&connected_dirs, dir_names[dir])
                } else {
                  log.warnf("  Invalid connection: span offset %d exceeds neighbor count %d", con_val, n_count)
                }
              } else {
                log.warnf("  Connection to empty cell (%d,%d)! con_val=%d", nx, ny, con_val)
              }
            }
          }
        }
        
        log.infof("  %s (%d,%d): %d connections - %v", 
          test.name, test.cell.x, test.cell.y, connections, connected_dirs[:])
          
        // Verify symmetry - if A connects to B, B should connect to A
        for dir in 0..<4 {
          con_val := get_con(s, dir)
          if con_val != NOT_CONNECTED {
            nx := test.cell.x + dir_offsets[dir].x
            ny := test.cell.y + dir_offsets[dir].y
            
            if nx >= 0 && nx < chf.width && ny >= 0 && ny < chf.height {
              neighbor_idx := nx + ny * chf.width
              neighbor_cell := &chf.cells[neighbor_idx]
              n_index, n_count := unpack_compact_cell(neighbor_cell.index)
              
              if n_count > 0 {
                neighbor_span_idx := i32(n_index) + i32(con_val)
                if neighbor_span_idx < chf.span_count {
                  neighbor_span := &chf.spans[neighbor_span_idx]
                  
                  // Check reverse connection
                  opposite_dir := (dir + 2) % 4  // Opposite direction
                  reverse_con := get_con(neighbor_span, opposite_dir)
                  
                  if reverse_con == NOT_CONNECTED {
                    log.warnf("    Asymmetric connection: (%d,%d)->(%d,%d) dir %d, but no reverse!",
                      test.cell.x, test.cell.y, nx, ny, dir)
                  } else {
                    // Verify the reverse connection points back to us
                    expected_reverse := span_idx - i32(cell_index)  // Our index within our cell
                    if reverse_con != u16(expected_reverse) {
                      log.warnf("    Asymmetric connection: (%d,%d)->(%d,%d) connects to span %d, but reverse connects to span %d (expected %d)!",
                        test.cell.x, test.cell.y, nx, ny, con_val, reverse_con, expected_reverse)
                    }
                  }
                }
              }
            }
          }
        }
      } else {
        log.infof("  %s (%d,%d): No spans (blocked cell)", test.name, test.cell.x, test.cell.y)
      }
    }
  }
  
  // Check connectivity statistics
  connected_count := 0
  for i in 0..<chf.span_count {
    s := &chf.spans[i]
    for dir in 0..<4 {
      if get_con(s, dir) != NOT_CONNECTED {
        connected_count += 1
      }
    }
  }
  log.infof("Total connections: %d (avg %.2f per span)", 
    connected_count, f32(connected_count)/f32(chf.span_count))
  
  // Count connectivity issues
  empty_cell_connections := 0
  asymmetric_connections := 0
  
  for y in 0..<chf.height {
    for x in 0..<chf.width {
      cell_idx := x + y * chf.width
      cell := &chf.cells[cell_idx]
      cell_index, cell_count := unpack_compact_cell(cell.index)
      
      if cell_count == 0 do continue
      
      for i in cell_index..<cell_index + u32(cell_count) {
        s := &chf.spans[i]
        
        for dir in 0..<4 {
          con_val := get_con(s, dir)
          if con_val != NOT_CONNECTED {
            nx := x + i32(dir == 0 ? -1 : (dir == 2 ? 1 : 0))  // West=-1, East=+1
            ny := y + i32(dir == 1 ? 1 : (dir == 3 ? -1 : 0))  // North=+1, South=-1
            
            if nx >= 0 && nx < chf.width && ny >= 0 && ny < chf.height {
              neighbor_idx := nx + ny * chf.width
              neighbor_cell := &chf.cells[neighbor_idx]
              n_index, n_count := unpack_compact_cell(neighbor_cell.index)
              
              if n_count == 0 {
                empty_cell_connections += 1
              } else if n_count > 0 {
                neighbor_span_idx := i32(n_index) + i32(con_val)
                if neighbor_span_idx < chf.span_count {
                  neighbor_span := &chf.spans[neighbor_span_idx]
                  opposite_dir := (dir + 2) % 4
                  reverse_con := get_con(neighbor_span, opposite_dir)
                  
                  if reverse_con == NOT_CONNECTED {
                    asymmetric_connections += 1
                  } else {
                    expected_reverse := i - cell_index
                    if reverse_con != u16(expected_reverse) {
                      asymmetric_connections += 1
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
  
  if empty_cell_connections > 0 || asymmetric_connections > 0 {
    log.warnf("Connectivity issues found: %d connections to empty cells, %d asymmetric connections", 
      empty_cell_connections, asymmetric_connections)
  } else {
    log.infof("Connectivity check passed: all connections are valid and symmetric")
  }

  // Step 5: Erode walkable area for agent radius
  log.infof("Eroding walkable area with radius: %d cells (cell_size=%.2f)", 
            config.walkable_radius, config.cs)
  if !erode_walkable_area(config.walkable_radius, chf) {
    log.error("Failed to erode walkable area")
    return NavMesh{}, false
  }

  // Step 6: Build distance field
  if !build_distance_field(chf) {
    log.error("Failed to build distance field")
    return NavMesh{}, false
  }

  // Step 7: Build regions
  if !build_regions(chf, config.border_size, config.min_region_area, config.merge_region_area) {
    log.error("Failed to build regions")
    return NavMesh{}, false
  }

  // Step 8: Build contours
  cset := alloc_contour_set()
  if cset == nil {
    log.error("Failed to allocate contour set")
    free_height_field(hf)
    free_compact_heightfield(chf)
    return NavMesh{}, false
  }
  // Note: Don't defer free_contour_set(cset) - we'll store it for visualization

  if !build_contours(chf, config.max_simplification_error, i32(config.max_edge_len), cset) {
    log.error("Failed to build contours")
    return NavMesh{}, false
  }

  // Step 9: Build polygon mesh
  pmesh := build_poly_mesh(cset, config.max_verts_per_poly)
  if pmesh == nil {
    log.error("Failed to build polygon mesh")
    free_height_field(hf)
    free_compact_heightfield(chf)
    free_contour_set(cset)
    return NavMesh{}, false
  }
  
  log.infof("build_poly_mesh: Created %d polygons, %d vertices", pmesh.npolys, pmesh.nverts)
  
  // Debug: Log polygon centers and bounds to understand layout
  log.debugf("Polygon centers and bounds:")
  for i in 0..<pmesh.npolys {
    center := [3]f32{0, 0, 0}
    min_bounds := [3]f32{999, 999, 999}
    max_bounds := [3]f32{-999, -999, -999}
    vert_count := 0
    for j in 0..<pmesh.nvp {
      vert_idx := pmesh.polys[i * pmesh.nvp * 2 + j]
      if vert_idx == 0xffff do break
      v_idx := vert_idx * 3
      wx := pmesh.bmin.x + f32(pmesh.verts[v_idx + 0]) * pmesh.cs
      wy := pmesh.bmin.y + f32(pmesh.verts[v_idx + 1]) * pmesh.ch
      wz := pmesh.bmin.z + f32(pmesh.verts[v_idx + 2]) * pmesh.cs
      center.x += wx
      center.y += wy
      center.z += wz
      min_bounds = linalg.min(min_bounds, [3]f32{wx, wy, wz})
      max_bounds = linalg.max(max_bounds, [3]f32{wx, wy, wz})
      vert_count += 1
    }
    if vert_count > 0 {
      center /= f32(vert_count)
      log.debugf("  Polygon %d: center [%.2f, %.2f, %.2f], bounds x[%.2f,%.2f] z[%.2f,%.2f]", 
                i, center.x, center.y, center.z, min_bounds.x, max_bounds.x, min_bounds.z, max_bounds.z)
    }
  }
  
  // Note: Don't defer free_poly_mesh(pmesh) - we'll store it for visualization

  // Step 10: Build detail mesh (optional, using stub for now)
  dmesh := alloc_poly_mesh_detail()
  if !build_poly_mesh_detail(pmesh, chf, config.detail_sample_dist, config.detail_sample_max_error, dmesh) {
    log.warn("Failed to build detail mesh, continuing without it")
  }
  // Note: Don't defer free_poly_mesh_detail(dmesh) - we'll free it explicitly after navmesh creation

  // Store debug data in builder
  builder.debug_heightfield = hf
  builder.debug_compact_hf = chf
  builder.debug_contours = cset
  builder.debug_poly_mesh = pmesh
  
  // Step 11: Create Detour navmesh from Recast polygon mesh
  navmesh, ok := create_navmesh_from_poly_mesh(pmesh, dmesh, config)
  
  // Free detail mesh as we don't need it for debug
  free_poly_mesh_detail(dmesh)
  
  log.infof("Navigation build returning: ok=%v, navmesh.tiles=%p", ok, navmesh.tiles)
  return navmesh, ok
}

// Create navigation mesh from heightfield
create_navmesh_from_heightfield :: proc(hf: ^Heightfield, config: Config) -> (NavMesh, bool) {
  // Count walkable cells to estimate polygon count
  walkable_cells := 0
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width
      s := hf.spans[idx]
      for s != nil {
        if s.area == WALKABLE_AREA {
          walkable_cells += 1
        }
        s = s.next
      }
    }
  }

  if walkable_cells == 0 {
    log.warn("No walkable cells found in heightfield")
    return NavMesh{}, false
  }

  log.infof("Found %d walkable cells in heightfield", walkable_cells)

  navmesh := NavMesh{
    max_tiles = 1,
    tile_width = f32(config.width),
    tile_height = f32(config.height),
    tiles = make([]MeshTile, 1),
  }

  tile := &navmesh.tiles[0]
  tile.salt = 1
  tile.header = new(MeshHeader)
  tile.header.magic = NAVMESH_MAGIC
  tile.header.version = NAVMESH_VERSION
  tile.header.bmin = config.bmin
  tile.header.bmax = config.bmax
  tile.header.walkable_height = f32(config.walkable_height)
  tile.header.walkable_radius = f32(config.walkable_radius)
  tile.header.walkable_climb = f32(config.walkable_climb)

  // Create vertices and polygons from walkable cells
  vertices := make([dynamic][3]f32)
  polygons := make([dynamic]Poly)
  defer delete(vertices)
  defer delete(polygons)

  // Generate quads for each walkable cell
  for z in 0..<hf.height {
    for x in 0..<hf.width {
      idx := x + z * hf.width
      s := hf.spans[idx]
      for s != nil {
        if s.area == WALKABLE_AREA {
          // Calculate world position of this cell
          wx := hf.bmin.x + f32(x) * hf.cs
          wz := hf.bmin.z + f32(z) * hf.cs
          wy := hf.bmin.y + f32(s.smax) * hf.ch

          // Add vertices for this cell (4 corners)
          base_vert := u32(len(vertices))
          append(&vertices, [3]f32{wx, wy, wz})
          append(&vertices, [3]f32{wx + hf.cs, wy, wz})
          append(&vertices, [3]f32{wx + hf.cs, wy, wz + hf.cs})
          append(&vertices, [3]f32{wx, wy, wz + hf.cs})

          // Create polygon (quad)
          poly := Poly{}
          poly.vert_count = 4
          poly.verts[0] = u16(base_vert + 0)
          poly.verts[1] = u16(base_vert + 1)
          poly.verts[2] = u16(base_vert + 2)
          poly.verts[3] = u16(base_vert + 3)
          poly.flags = 1 // Walkable
          set_poly_area(&poly, WALKABLE_AREA)

          // Initialize neighbor links
          for i in 0..<4 {
            poly.neis[i] = NOT_CONNECTED
          }

          append(&polygons, poly)
        }
        s = s.next
      }
    }
  }

  // Copy vertices to tile
  tile.header.vert_count = i32(len(vertices))
  tile.verts = make([]f32, len(vertices) * 3)
  for v, i in vertices {
    tile.verts[i*3 + 0] = v.x
    tile.verts[i*3 + 1] = v.y
    tile.verts[i*3 + 2] = v.z
  }

  // Copy polygons to tile
  tile.header.poly_count = i32(len(polygons))
  tile.polys = make([]Poly, len(polygons))
  copy(tile.polys, polygons[:])

  log.infof("Created navigation mesh with %d vertices, %d polygons from heightfield",
    len(vertices), len(polygons))

  return navmesh, true
}

// Create Detour navmesh from Recast polygon mesh
create_navmesh_from_poly_mesh :: proc(pmesh: ^PolyMesh, dmesh: ^PolyMeshDetail, config: Config) -> (NavMesh, bool) {
  if pmesh == nil || pmesh.nverts == 0 || pmesh.npolys == 0 {
    log.error("Invalid polygon mesh for navmesh creation")
    return NavMesh{}, false
  }

  navmesh := NavMesh{
    max_tiles = 1,
    tile_width = f32(config.width),
    tile_height = f32(config.height),
    tiles = make([]MeshTile, 1),
  }

  tile := &navmesh.tiles[0]
  tile.salt = 1
  tile.header = new(MeshHeader)
  tile.header.magic = NAVMESH_MAGIC
  tile.header.version = NAVMESH_VERSION
  tile.header.bmin = pmesh.bmin
  tile.header.bmax = pmesh.bmax
  tile.header.walkable_height = f32(config.walkable_height) * config.ch
  tile.header.walkable_radius = f32(config.walkable_radius) * config.cs
  tile.header.walkable_climb = f32(config.walkable_climb) * config.ch
  tile.header.vert_count = pmesh.nverts
  tile.header.poly_count = pmesh.npolys

  // Convert vertices from grid coordinates to world coordinates
  tile.verts = make([]f32, pmesh.nverts * 3)
  for i in 0..<pmesh.nverts {
    idx := i * 3
    x := pmesh.bmin.x + f32(pmesh.verts[idx + 0]) * pmesh.cs
    y := pmesh.bmin.y + f32(pmesh.verts[idx + 1]) * pmesh.ch
    z := pmesh.bmin.z + f32(pmesh.verts[idx + 2]) * pmesh.cs
    
    // Clamp vertices to input bounds to prevent expansion beyond original geometry
    // This prevents pathfinding issues where portal vertices extend outside the mesh
    x = clamp(x, config.bmin.x, config.bmax.x)
    z = clamp(z, config.bmin.z, config.bmax.z)
    
    tile.verts[idx + 0] = x
    tile.verts[idx + 1] = y
    tile.verts[idx + 2] = z
  }

  // Convert polygons
  tile.polys = make([]Poly, pmesh.npolys)
  for i in 0..<pmesh.npolys {
    src_poly := i * pmesh.nvp * 2
    dst_poly := &tile.polys[i]

    // Count vertices
    vert_count := 0
    for j in 0..<pmesh.nvp {
      if pmesh.polys[src_poly + j] == 0xffff do break
      vert_count += 1
    }

    dst_poly.vert_count = u8(vert_count)

    // Copy vertex indices
    for j in 0..<vert_count {
      dst_poly.verts[j] = pmesh.polys[src_poly + i32(j)]
    }

    // Copy neighbor information
    for j in 0..<vert_count {
      neighbor := pmesh.polys[src_poly + pmesh.nvp + i32(j)]
      if neighbor == 0xffff {
        dst_poly.neis[j] = 0  // Detour uses 0 for no neighbor
      } else {
        // PolyMesh stores 0-based indices, but we'll use 1-based for consistency
        // This matches how we'll interpret them when building links
        dst_poly.neis[j] = u16(neighbor) + 1
      }
    }

    // Set area and flags
    set_poly_area(dst_poly, pmesh.areas[i])
    dst_poly.flags = pmesh.flags[i]
  }

  // Initialize links with dynamic array
  links := make([dynamic]Link)
  
  // Build polygon connectivity
  total_links := 0
  polys_with_links := 0
  
  for i in 0..<tile.header.poly_count {
    poly := &tile.polys[i]
    poly.first_link = NULL_LINK
    poly_link_count := 0

    for j in 0..<poly.vert_count {
      if j == 0 && i < 5 {  // Debug first few polygons
        log.debugf("Poly %d edge %d: neighbor = %d (0 means no neighbor)", i, j, poly.neis[j])
      }
      
      if poly.neis[j] != 0 {
        // Create link to neighbor (neis stores 1-based indices)
        neighbor_idx := u32(poly.neis[j] - 1)  // Convert to 0-based
        if neighbor_idx < u32(tile.header.poly_count) {
          link_idx := u32(len(links))
          link := Link{
            ref = encode_poly_id(tile.salt, 0, neighbor_idx),
            edge = u8(j),
            side = 0xff,
            bmin = 0,
            bmax = 0,
            next = poly.first_link,
          }
        
          append(&links, link)
          poly.first_link = link_idx
          poly_link_count += 1
          total_links += 1
        }
      }
    }
    
    if poly_link_count > 0 {
      polys_with_links += 1
    }
  }
  
  log.infof("Created %d links for %d/%d polygons", total_links, polys_with_links, tile.header.poly_count)
  
  // Validate connectivity
  connectivity_issues := 0
  asymmetric_connections := 0
  
  for i in 0..<tile.header.poly_count {
    poly := &tile.polys[i]
    
    // Check each neighbor reference
    for link_idx := poly.first_link; link_idx != NULL_LINK; {
      if link_idx >= u32(len(links)) do break
      link := &links[link_idx]
      
      // Decode neighbor reference
      neighbor_tile := decode_poly_id_tile(link.ref)
      neighbor_poly := decode_poly_id_poly(link.ref)
      
      if neighbor_tile != 0 || neighbor_poly >= u32(tile.header.poly_count) {
        log.warnf("Polygon %d has invalid neighbor reference: tile=%d, poly=%d", i, neighbor_tile, neighbor_poly)
        connectivity_issues += 1
      } else {
        // Check if neighbor has reciprocal link back to us
        neighbor := &tile.polys[neighbor_poly]
        found_reciprocal := false
        
        for nlink_idx := neighbor.first_link; nlink_idx != NULL_LINK; {
          if nlink_idx >= u32(len(links)) do break
          nlink := &links[nlink_idx]
          
          if decode_poly_id_poly(nlink.ref) == u32(i) {
            found_reciprocal = true
            break
          }
          
          nlink_idx = nlink.next
        }
        
        if !found_reciprocal {
          if asymmetric_connections < 5 {  // Log first few for debugging
            log.warnf("Asymmetric connection: poly %d -> %d has no reciprocal link", i, neighbor_poly)
          }
          asymmetric_connections += 1
        }
      }
      
      link_idx = link.next
    }
  }
  
  if connectivity_issues > 0 || asymmetric_connections > 0 {
    log.warnf("Connectivity issues found: %d connections to invalid polygons, %d asymmetric connections", 
              connectivity_issues, asymmetric_connections)
  }
  
  // Convert dynamic array to slice - allocate new slice and copy
  tile.links = make([]Link, len(links))
  copy(tile.links, links[:])
  delete(links)
  tile.header.max_link_count = i32(len(tile.links))

  log.infof("Created Detour navmesh with %d vertices, %d polygons", tile.header.vert_count, tile.header.poly_count)
  log.infof("NavMesh tiles: %p, tile[0].verts: %p, tile[0].polys: %p", navmesh.tiles, tile.verts, tile.polys)

  return navmesh, true
}

triangle_overlaps_box_2d :: proc(a, b, c: [2]f32, box_min, box_max: [2]f32) -> bool {
  min_x := min(a.x, b.x, c.x)
  max_x := max(a.x, b.x, c.x)
  min_y := min(a.y, b.y, c.y)
  max_y := max(a.y, b.y, c.y)

  if max_x < box_min.x || min_x > box_max.x do return false
  if max_y < box_min.y || min_y > box_max.y do return false

  if a.x >= box_min.x && a.x <= box_max.x && a.y >= box_min.y && a.y <= box_max.y do return true
  if b.x >= box_min.x && b.x <= box_max.x && b.y >= box_min.y && b.y <= box_max.y do return true
  if c.x >= box_min.x && c.x <= box_max.x && c.y >= box_min.y && c.y <= box_max.y do return true

  v0 := [2]f32{box_min.x, box_min.y}
  v1 := [2]f32{box_max.x, box_min.y}
  v2 := [2]f32{box_max.x, box_max.y}
  v3 := [2]f32{box_min.x, box_max.y}

  if point_in_triangle_2d(v0, a, b, c) do return true
  if point_in_triangle_2d(v1, a, b, c) do return true
  if point_in_triangle_2d(v2, a, b, c) do return true
  if point_in_triangle_2d(v3, a, b, c) do return true

  // Check edge-edge intersections
  if line_segments_intersect_2d(a, b, v0, v1) do return true
  if line_segments_intersect_2d(a, b, v1, v2) do return true
  if line_segments_intersect_2d(a, b, v2, v3) do return true
  if line_segments_intersect_2d(a, b, v3, v0) do return true
  
  if line_segments_intersect_2d(b, c, v0, v1) do return true
  if line_segments_intersect_2d(b, c, v1, v2) do return true
  if line_segments_intersect_2d(b, c, v2, v3) do return true
  if line_segments_intersect_2d(b, c, v3, v0) do return true
  
  if line_segments_intersect_2d(c, a, v0, v1) do return true
  if line_segments_intersect_2d(c, a, v1, v2) do return true
  if line_segments_intersect_2d(c, a, v2, v3) do return true
  if line_segments_intersect_2d(c, a, v3, v0) do return true

  return false
}

point_in_triangle_2d :: proc(p, a, b, c: [2]f32) -> bool {
  v0 := c - a
  v1 := b - a
  v2 := p - a

  dot00 := linalg.dot(v0, v0)
  dot01 := linalg.dot(v0, v1)
  dot02 := linalg.dot(v0, v2)
  dot11 := linalg.dot(v1, v1)
  dot12 := linalg.dot(v1, v2)

  inv_denom := 1.0 / (dot00 * dot11 - dot01 * dot01)
  u := (dot11 * dot02 - dot01 * dot12) * inv_denom
  v := (dot00 * dot12 - dot01 * dot02) * inv_denom

  return (u >= 0) && (v >= 0) && (u + v <= 1)
}

line_segments_intersect_2d :: proc(p1, q1, p2, q2: [2]f32) -> bool {
  d1 := q1 - p1
  d2 := q2 - p2
  
  cross := d1.x * d2.y - d1.y * d2.x
  
  // Parallel lines
  if abs(cross) < 0.0001 do return false
  
  t1 := ((p2.x - p1.x) * d2.y - (p2.y - p1.y) * d2.x) / cross
  t2 := ((p2.x - p1.x) * d1.y - (p2.y - p1.y) * d1.x) / cross
  
  return t1 >= 0 && t1 <= 1 && t2 >= 0 && t2 <= 1
}
