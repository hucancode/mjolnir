package test_recast

import "core:log"
import "core:testing"
import "core:time"
import "core:math"
import nav_recast "../../mjolnir/navigation/recast"

// Final integration test: Complete navmesh generation for a scene with walkable field and obstacle
@(test)
test_scene_with_obstacle :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    log.info("=== Testing complete navmesh generation with walkable field and obstacle ===")

    // Create configuration for a 20x20 unit field
    config := nav_recast.Config{
        width = 64,
        height = 64,
        tile_size = 0,
        border_size = 4,
        cs = 0.3,  // Cell size
        ch = 0.2,  // Cell height
        bmin = {-10, 0, -10},
        bmax = {10, 5, 10},
        walkable_slope_angle = 45.0,
        walkable_height = 10,  // 2 meters
        walkable_climb = 4,    // 0.8 meters
        walkable_radius = 2,   // 0.6 meters
        max_edge_len = 12,
        max_simplification_error = 1.3,
        min_region_area = 64,
        merge_region_area = 400,
        max_verts_per_poly = 6,
        detail_sample_dist = 6.0,
        detail_sample_max_error = 1.0,
    }

    // Calculate grid dimensions
    config.width, config.height = nav_recast.calc_grid_size(config.bmin, config.bmax, config.cs)

    // Create input mesh: flat ground with a box obstacle in the middle
    vertices := make([dynamic]f32)
    defer delete(vertices)
    triangles := make([dynamic]i32)
    defer delete(triangles)

    // Ground plane (large square from -10 to 10 in X and Z)
    ground_y := f32(0.0)
    append(&vertices, -10, ground_y, -10)  // 0
    append(&vertices,  10, ground_y, -10)  // 1
    append(&vertices,  10, ground_y,  10)  // 2
    append(&vertices, -10, ground_y,  10)  // 3

    // Ground triangles
    append(&triangles, 0, 1, 2)
    append(&triangles, 0, 2, 3)

    // Box obstacle in the center (2x2x3 units)
    box_min_x, box_max_x := f32(-1), f32(1)
    box_min_z, box_max_z := f32(-1), f32(1)
    box_min_y, box_max_y := f32(0), f32(3)

    base_idx := i32(len(vertices) / 3)

    // Box vertices (8 vertices)
    append(&vertices, box_min_x, box_min_y, box_min_z)  // 4: bottom-front-left
    append(&vertices, box_max_x, box_min_y, box_min_z)  // 5: bottom-front-right
    append(&vertices, box_max_x, box_min_y, box_max_z)  // 6: bottom-back-right
    append(&vertices, box_min_x, box_min_y, box_max_z)  // 7: bottom-back-left
    append(&vertices, box_min_x, box_max_y, box_min_z)  // 8: top-front-left
    append(&vertices, box_max_x, box_max_y, box_min_z)  // 9: top-front-right
    append(&vertices, box_max_x, box_max_y, box_max_z)  // 10: top-back-right
    append(&vertices, box_min_x, box_max_y, box_max_z)  // 11: top-back-left

    // Box faces (12 triangles, 2 per face)
    // Bottom face
    append(&triangles, base_idx+0, base_idx+2, base_idx+1)
    append(&triangles, base_idx+0, base_idx+3, base_idx+2)

    // Top face
    append(&triangles, base_idx+4, base_idx+5, base_idx+6)
    append(&triangles, base_idx+4, base_idx+6, base_idx+7)

    // Front face
    append(&triangles, base_idx+0, base_idx+1, base_idx+5)
    append(&triangles, base_idx+0, base_idx+5, base_idx+4)

    // Back face
    append(&triangles, base_idx+2, base_idx+3, base_idx+7)
    append(&triangles, base_idx+2, base_idx+7, base_idx+6)

    // Left face
    append(&triangles, base_idx+0, base_idx+4, base_idx+7)
    append(&triangles, base_idx+0, base_idx+7, base_idx+3)

    // Right face
    append(&triangles, base_idx+1, base_idx+2, base_idx+6)
    append(&triangles, base_idx+1, base_idx+6, base_idx+5)

    log.infof("Created scene mesh: %d vertices, %d triangles", len(vertices)/3, len(triangles)/3)

    // Step 1: Create solid heightfield
    solid := nav_recast.alloc_heightfield()
    defer nav_recast.free_heightfield(solid)

    ok := nav_recast.create_heightfield(solid, config.width, config.height,
                                           config.bmin, config.bmax,
                                           config.cs, config.ch)
    testing.expect(t, ok, "Failed to create heightfield")

    // Step 2: Rasterize triangles
    areas := make([]u8, len(triangles)/3)
    defer delete(areas)

    // Mark all triangles as walkable initially
    for i in 0..<len(areas) {
        areas[i] = nav_recast.RC_WALKABLE_AREA
    }

    nav_recast.rasterize_triangles(
        vertices[:], i32(len(vertices)/3),
        triangles[:], areas[:], i32(len(triangles)/3),
        solid, config.walkable_climb,
    )

    // Step 3: Filter walkable surfaces
    nav_recast.filter_low_hanging_walkable_obstacles(int(config.walkable_climb), solid)
    nav_recast.filter_ledge_spans(int(config.walkable_height), int(config.walkable_climb), solid)
    nav_recast.filter_walkable_low_height_spans(int(config.walkable_height), solid)

    // Step 4: Create compact heightfield
    chf := nav_recast.alloc_compact_heightfield()
    defer nav_recast.free_compact_heightfield(chf)

    ok = nav_recast.build_compact_heightfield(config.walkable_height, config.walkable_climb, solid, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Step 5: Erode walkable area
    ok = nav_recast.erode_walkable_area(config.walkable_radius, chf)
    testing.expect(t, ok, "Failed to erode walkable area")

    // Step 6: Build distance field
    ok = nav_recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    // Step 7: Build regions
    ok = nav_recast.build_regions(chf, config.border_size,
                                    config.min_region_area, config.merge_region_area)
    testing.expect(t, ok, "Failed to build regions")

    // Verify we have regions
    max_region := u16(0)
    for i in 0..<chf.span_count {
        if chf.spans[i].reg > max_region {
            max_region = chf.spans[i].reg
        }
    }
    testing.expect(t, max_region > 0, "Should have at least one region")
    log.infof("Created %d regions", max_region)

    // Step 8: Build contours
    cset := nav_recast.alloc_contour_set()
    defer nav_recast.free_contour_set(cset)

    ok = nav_recast.build_contours(chf, config.max_simplification_error,
                                      config.max_edge_len, cset)
    testing.expect(t, ok, "Failed to build contours")
    testing.expect(t, len(cset.conts) > 0, "Should have at least one contour")

    log.infof("Built %d contours", len(cset.conts))

    // Verify contours
    total_contour_verts := 0
    for i in 0..<len(cset.conts) {
        cont := &cset.conts[i]
        testing.expect(t, len(cont.verts) >= 3, "Each contour should have at least 3 vertices")
        total_contour_verts += len(cont.verts)

        // Check that contour vertices are reasonable
        for j in 0..<len(cont.verts) {
            x := cont.verts[j][0]
            y := cont.verts[j][1]
            z := cont.verts[j][2]

            // Vertices should be within bounds (in grid coordinates)
            testing.expect(t, x >= -5 && x <= config.width + 5, "Contour X coordinate out of bounds")
            testing.expect(t, z >= -5 && z <= config.height + 5, "Contour Z coordinate out of bounds")
        }
    }

    log.infof("Total contour vertices: %d", total_contour_verts)

    // Step 9: Build polygon mesh
    pmesh := nav_recast.alloc_poly_mesh()
    defer nav_recast.free_poly_mesh(pmesh)

    ok = nav_recast.build_poly_mesh(cset, config.max_verts_per_poly, pmesh)
    testing.expect(t, ok, "Failed to build polygon mesh")
    testing.expect(t, len(pmesh.verts) > 0, "Should have vertices in polygon mesh")
    testing.expect(t, pmesh.npolys > 0, "Should have polygons in polygon mesh")

    log.infof("Built polygon mesh: %d vertices, %d polygons", len(pmesh.verts), pmesh.npolys)

    // Verify polygon mesh
    testing.expect(t, nav_recast.validate_poly_mesh(pmesh), "Polygon mesh should be valid")

    // Check that we have a reasonable mesh structure
    // The ground should be mostly covered except where the obstacle is
    testing.expect(t, len(pmesh.verts) >= 4, "Should have at least 4 vertices for ground corners")
    testing.expect(t, pmesh.npolys >= 1, "Should have at least 1 polygon")

    // Verify mesh bounds are reasonable
    min_x, min_z := i32(1000000), i32(1000000)
    max_x, max_z := i32(-1000000), i32(-1000000)

    for i in 0..<len(pmesh.verts) {
        x := i32(pmesh.verts[i][0])
        z := i32(pmesh.verts[i][2])
        min_x = min(min_x, x)
        max_x = max(max_x, x)
        min_z = min(min_z, z)
        max_z = max(max_z, z)
    }

    log.infof("Mesh bounds: X[%d, %d], Z[%d, %d]", min_x, max_x, min_z, max_z)

    // The mesh should roughly cover the ground area
    testing.expect(t, max_x - min_x > 10, "Mesh should span significant X distance")
    testing.expect(t, max_z - min_z > 10, "Mesh should span significant Z distance")

    // Step 10: Build detail mesh (optional but good to test)
    dmesh := nav_recast.alloc_poly_mesh_detail()
    defer nav_recast.free_poly_mesh_detail(dmesh)

    ok = nav_recast.build_poly_mesh_detail(pmesh, chf,
                                              config.detail_sample_dist,
                                              config.detail_sample_max_error, dmesh)
    testing.expect(t, ok, "Failed to build detail mesh")
    testing.expect(t, len(dmesh.meshes) == int(pmesh.npolys), "Should have detail mesh for each polygon")

    log.infof("Built detail mesh: %d meshes, %d vertices, %d triangles",
              len(dmesh.meshes), len(dmesh.verts), len(dmesh.tris))

    // Final validation
    log.info("=== Scene navmesh generation completed successfully ===")
    log.infof("Summary:")
    log.infof("  - Heightfield: %dx%d cells", config.width, config.height)
    log.infof("  - Regions: %d", max_region)
    log.infof("  - Contours: %d (total %d vertices)", len(cset.conts), total_contour_verts)
    log.infof("  - Polygon mesh: %d vertices, %d polygons", len(pmesh.verts), pmesh.npolys)
    log.infof("  - Detail mesh: %d vertices, %d triangles", len(dmesh.verts), len(dmesh.tris))

    // The obstacle should create a hole in the navmesh
    // We expect the navmesh to wrap around the obstacle
    testing.expect(t, pmesh.npolys >= 4,
                   "Should have multiple polygons to navigate around obstacle")
}

// Test contour generation with real heightfield data
@(test)
test_contour_with_real_heightfield :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a more realistic heightfield with varying heights
    config := nav_recast.Config{
        width = 32,
        height = 32,
        cs = 0.5,
        ch = 0.2,
        bmin = {0, 0, 0},
        bmax = {16, 4, 16},
        walkable_height = 10,
        walkable_climb = 4,
        walkable_radius = 2,
        max_simplification_error = 1.3,
        max_edge_len = 12,
        min_region_area = 20,
        merge_region_area = 100,
    }

    // Create heightfield
    solid := nav_recast.alloc_heightfield()
    defer nav_recast.free_heightfield(solid)

    ok := nav_recast.create_heightfield(solid, config.width, config.height,
                                          config.bmin, config.bmax,
                                          config.cs, config.ch)
    testing.expect(t, ok, "Failed to create heightfield")

    // Add some terrain features
    vertices := make([dynamic]f32)
    defer delete(vertices)
    triangles := make([dynamic]i32)
    defer delete(triangles)

    // Create a terrain with a hill in the middle
    grid_size := 9
    for z in 0..<grid_size {
        for x in 0..<grid_size {
            fx := f32(x) * 2.0
            fz := f32(z) * 2.0

            // Height function: raised in the middle
            dist_from_center := math.sqrt((fx-8)*(fx-8) + (fz-8)*(fz-8))
            height := math.max(0, 2.0 - dist_from_center * 0.2)

            append(&vertices, fx, height, fz)
        }
    }

    // Create triangles for the terrain grid
    for z in 0..<grid_size-1 {
        for x in 0..<grid_size-1 {
            v0 := i32(z * grid_size + x)
            v1 := v0 + 1
            v2 := v0 + i32(grid_size)
            v3 := v2 + 1

            append(&triangles, v0, v1, v3)
            append(&triangles, v0, v3, v2)
        }
    }

    // Rasterize
    areas := make([]u8, len(triangles)/3)
    defer delete(areas)
    for i in 0..<len(areas) {
        areas[i] = nav_recast.RC_WALKABLE_AREA
    }

    nav_recast.rasterize_triangles(
        vertices[:], i32(len(vertices)/3),
        triangles[:], areas[:], i32(len(triangles)/3),
        solid, config.walkable_climb,
    )

    // Build compact heightfield
    chf := nav_recast.alloc_compact_heightfield()
    defer nav_recast.free_compact_heightfield(chf)

    ok = nav_recast.build_compact_heightfield(config.walkable_height, config.walkable_climb, solid, chf)
    testing.expect(t, ok, "Failed to build compact heightfield")

    // Build regions
    ok = nav_recast.build_distance_field(chf)
    testing.expect(t, ok, "Failed to build distance field")

    ok = nav_recast.build_regions(chf, 0, config.min_region_area, config.merge_region_area)
    testing.expect(t, ok, "Failed to build regions")

    // Build contours
    cset := nav_recast.alloc_contour_set()
    defer nav_recast.free_contour_set(cset)

    ok = nav_recast.build_contours(chf, config.max_simplification_error, config.max_edge_len, cset)
    testing.expect(t, ok, "Failed to build contours")

    // Verify contours follow the terrain
    testing.expect(t, len(cset.conts) > 0, "Should have contours for terrain")

    for i in 0..<len(cset.conts) {
        cont := &cset.conts[i]
        testing.expect(t, len(cont.verts) >= 3, "Contour should have valid shape")

        // Check height variation in contour
        min_y, max_y := i32(1000000), i32(-1000000)
        for j in 0..<len(cont.verts) {
            y := cont.verts[j][1]
            min_y = min(min_y, y)
            max_y = max(max_y, y)
        }

        // Contours on terrain should have some height variation
        log.infof("Contour %d: height range [%d, %d]", i, min_y, max_y)
    }

    log.infof("Terrain contour test: generated %d contours", len(cset.conts))
}
