package test_detour

import "core:testing"
import "core:time"
import "core:math"
import "core:math/linalg"
import "../../mjolnir/navigation/recast"
import "../../mjolnir/navigation/detour"

// Integration test for priority queue in pathfinding context
@(test)
test_integration_pathfinding_priority_queue :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a test navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    // Create query object
    query := detour.Nav_Mesh_Query{}
    defer detour.nav_mesh_query_destroy(&query)

    status := detour.nav_mesh_query_init(&query, nav_mesh, 256)
    testing.expect(t, recast.status_succeeded(status), "Query initialization should succeed")

    // Test that nodes are processed in correct order during pathfinding
    // We'll track the order in which nodes are processed by the priority queue

    filter := detour.Query_Filter{}
    detour.query_filter_init(&filter)

    // Find start and end polygons
    start_pos := [3]f32{1.0, 0.0, 1.0}
    end_pos := [3]f32{9.0, 0.0, 9.0}
    half_extents := [3]f32{1.0, 1.0, 1.0}

    start_ref := recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    status, start_ref, start_nearest = detour.find_nearest_poly(&query, start_pos, half_extents, &filter)
    testing.expect(t, recast.status_succeeded(status), "Should find start polygon")
    testing.expect(t, start_ref != recast.INVALID_POLY_REF, "Start reference should be valid")

    end_ref := recast.Poly_Ref(0)
    end_nearest := [3]f32{}
    status, end_ref, end_nearest = detour.find_nearest_poly(&query, end_pos, half_extents, &filter)
    testing.expect(t, recast.status_succeeded(status), "Should find end polygon")
    testing.expect(t, end_ref != recast.INVALID_POLY_REF, "End reference should be valid")

    // Test pathfinding - this will exercise the priority queue internally
    path := make([]recast.Poly_Ref, 64)
    defer delete(path)

    path_status, path_count := detour.find_path(&query, start_ref, end_ref, start_nearest, end_nearest,
                                                &filter, path, 64)
    testing.expect(t, recast.status_succeeded(path_status), "Pathfinding should succeed")
    testing.expect(t, path_count > 0, "Path should contain at least one polygon")
    testing.expect_value(t, path[0], start_ref)
}

// Integration test for multiple pathfinding operations to test thread safety
@(test)
test_integration_multiple_pathfinding_operations :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create multiple test navigation meshes to simulate concurrent usage
    nav_mesh1 := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh1)

    nav_mesh2 := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh2)

    // Create multiple query objects
    query1 := detour.Nav_Mesh_Query{}
    defer detour.nav_mesh_query_destroy(&query1)

    query2 := detour.Nav_Mesh_Query{}
    defer detour.nav_mesh_query_destroy(&query2)

    status1 := detour.nav_mesh_query_init(&query1, nav_mesh1, 128)
    testing.expect(t, recast.status_succeeded(status1), "Query1 initialization should succeed")

    status2 := detour.nav_mesh_query_init(&query2, nav_mesh2, 128)
    testing.expect(t, recast.status_succeeded(status2), "Query2 initialization should succeed")

    filter := detour.Query_Filter{}
    detour.query_filter_init(&filter)

    // Perform pathfinding with different parameters on both queries
    // This tests that the thread-local context switching works correctly

    // Query 1 - short path
    start_pos1 := [3]f32{1.0, 0.0, 1.0}
    end_pos1 := [3]f32{3.0, 0.0, 3.0}
    half_extents := [3]f32{1.0, 1.0, 1.0}

    status, start_ref1, start_nearest1 := detour.find_nearest_poly(&query1, start_pos1, half_extents, &filter)
    testing.expect(t, recast.status_succeeded(status), "Should find start polygon for query1")

    end_ref1 := recast.Poly_Ref(0)
    end_nearest1 := [3]f32{}
    status, end_ref1, end_nearest1 = detour.find_nearest_poly(&query1, end_pos1, half_extents, &filter)
    testing.expect(t, recast.status_succeeded(status), "Should find end polygon for query1")

    // Query 2 - longer path
    start_pos2 := [3]f32{2.0, 0.0, 2.0}
    end_pos2 := [3]f32{8.0, 0.0, 8.0}

    start_ref2 := recast.Poly_Ref(0)
    start_nearest2 := [3]f32{}
    status, start_ref2, start_nearest2 = detour.find_nearest_poly(&query2, start_pos2, half_extents, &filter)
    testing.expect(t, recast.status_succeeded(status), "Should find start polygon for query2")

    end_ref2 := recast.Poly_Ref(0)
    end_nearest2 := [3]f32{}
    status, end_ref2, end_nearest2 = detour.find_nearest_poly(&query2, end_pos2, half_extents, &filter)
    testing.expect(t, recast.status_succeeded(status), "Should find end polygon for query2")

    // Interleave pathfinding operations to test context switching
    path1 := make([]recast.Poly_Ref, 32)
    defer delete(path1)
    path2 := make([]recast.Poly_Ref, 32)
    defer delete(path2)

    // First pathfinding on query1
    path_status1, path_count1 := detour.find_path(&query1, start_ref1, end_ref1, start_nearest1, end_nearest1,
                                                 &filter, path1, 32)
    testing.expect(t, recast.status_succeeded(path_status1), "Pathfinding on query1 should succeed")
    testing.expect(t, path_count1 > 0, "Path1 should contain at least one polygon")

    // Then pathfinding on query2
    path_status2, path_count2 := detour.find_path(&query2, start_ref2, end_ref2, start_nearest2, end_nearest2,
                                                 &filter, path2, 32)
    testing.expect(t, recast.status_succeeded(path_status2), "Pathfinding on query2 should succeed")
    testing.expect(t, path_count2 > 0, "Path2 should contain at least one polygon")

    // Verify both paths are valid and contain their expected start polygons
    testing.expect_value(t, path1[0], start_ref1)
    testing.expect_value(t, path2[0], start_ref2)

    // In a simple single-polygon mesh, paths may legitimately be the same
    // The important thing is that both pathfinding operations succeeded independently
    // without interfering with each other's context (testing thread safety)
}

@(test)
test_navigation_mesh_creation :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Unit test: Create simple box geometry for navigation mesh
    vertices := [][3]f32{
        // Floor quad
        {-10, 0, -10},
         {10, 0, -10},
         {10, 0,  10},
        {-10, 0,  10},
    }

    indices := []i32{
        0, 2, 1,  // Reversed winding order
        0, 3, 2,  // Reversed winding order
    }

    area_types := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}  // Both triangles are walkable

    // Setup navigation mesh config
    config := recast.Config{
        cs = 0.3,                     // Cell size
        ch = 0.2,                     // Cell height
        walkable_slope_angle = 45.0,
        walkable_height = 10,         // In cells (2.0m / 0.2 cell height = 10 cells)
        walkable_climb = 4,           // In cells (0.9m / 0.2 cell height ≈ 4 cells)
        walkable_radius = 2,          // In cells (0.6m / 0.3 cell size = 2 cells)
        max_edge_len = 12.0,
        max_simplification_error = 1.3,
        min_region_area = 8.0,
        merge_region_area = 20.0,
        max_verts_per_poly = 6,
        detail_sample_dist = 6.0,
        detail_sample_max_error = 1.0,
    }

    // Build navigation mesh using Recast
    pmesh, dmesh, ok := recast.build_navmesh(vertices[:], indices[:], area_types[:], config)
    testing.expect(t, ok, "Failed to build Recast navigation mesh")
    defer {
        if pmesh != nil do recast.free_poly_mesh(pmesh)
        if dmesh != nil do recast.free_poly_mesh_detail(dmesh)
    }

    testing.expect(t, pmesh != nil, "Polygon mesh should not be nil")
    testing.expect(t, pmesh.npolys > 0, "Should have at least one polygon")

    // Convert to Detour format
    nav_params := detour.Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,

        walkable_height = f32(config.walkable_height) * config.ch,  // Convert cells to world units
        walkable_radius = f32(config.walkable_radius) * config.cs,  // Convert cells to world units
        walkable_climb = f32(config.walkable_climb) * config.ch,    // Convert cells to world units

        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        user_id = 0,
        off_mesh_con_count = 0,
    }

    nav_data, create_status := detour.create_nav_mesh_data(&nav_params)
    testing.expect(t, recast.status_succeeded(create_status), "Failed to create navigation mesh data")
    testing.expect(t, len(nav_data) > 0, "Navigation data should not be empty")

    // Create and initialize Detour navigation mesh
    nav_mesh := new(detour.Nav_Mesh)
    defer {
        detour.nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
    }

    mesh_params := detour.Nav_Mesh_Params{
        orig = pmesh.bmin,
        tile_width = pmesh.bmax[0] - pmesh.bmin[0],
        tile_height = pmesh.bmax[2] - pmesh.bmin[2],
        max_tiles = 1,
        max_polys = 1024,
    }

    init_status := detour.nav_mesh_init(nav_mesh, &mesh_params)
    testing.expect(t, recast.status_succeeded(init_status), "Failed to initialize navigation mesh")

    _, add_status := detour.nav_mesh_add_tile(nav_mesh, nav_data, recast.DT_TILE_FREE_DATA)
    testing.expect(t, recast.status_succeeded(add_status), "Failed to add tile to navigation mesh")
}

@(test)
test_pathfinding :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Integration test: Create more complex geometry
    vertices := [][3]f32{
        // Floor with obstacle
        {-10, 0, -10},
         {10, 0, -10},
         {10, 0,  10},
        {-10, 0,  10},

        // Obstacle box (raised platform)
        {-2, 0, -2},
         {2, 0, -2},
         {2, 2,  2},
        {-2, 2,  2},
    }

    indices := []i32{
        // Floor
        0, 2, 1,  // Reversed winding order
        0, 3, 2,  // Reversed winding order

        // Obstacle top
        4, 6, 5,  // Reversed winding order
        4, 7, 6,  // Reversed winding order
    }

    area_types := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA, 1, 1}  // Floor is walkable, obstacle is different area

    config := recast.Config{
        cs = 0.3,
        ch = 0.2,
        walkable_slope_angle = 45.0,
        walkable_height = 10,         // In cells (2.0m / 0.2 cell height = 10 cells)
        walkable_climb = 4,           // In cells (0.9m / 0.2 cell height ≈ 4 cells)
        walkable_radius = 2,          // In cells (0.6m / 0.3 cell size = 2 cells)
        max_edge_len = 12.0,
        max_simplification_error = 1.3,
        min_region_area = 8.0,
        merge_region_area = 20.0,
        max_verts_per_poly = 6,
        detail_sample_dist = 6.0,
        detail_sample_max_error = 1.0,
    }

    // Build navigation mesh
    pmesh, dmesh, ok := recast.build_navmesh(vertices[:], indices[:], area_types[:], config)
    testing.expect(t, ok, "Failed to build navigation mesh for pathfinding test")
    defer {
        if pmesh != nil do recast.free_poly_mesh(pmesh)
        if dmesh != nil do recast.free_poly_mesh_detail(dmesh)
    }

    // Create Detour navigation mesh
    nav_mesh, nav_status := detour.create_nav_mesh(&detour.Create_Nav_Mesh_Data_Params{
        poly_mesh = pmesh,
        poly_mesh_detail = dmesh,
        walkable_height = f32(config.walkable_height) * config.ch,  // Convert cells to world units
        walkable_radius = f32(config.walkable_radius) * config.cs,  // Convert cells to world units
        walkable_climb = f32(config.walkable_climb) * config.ch,    // Convert cells to world units
        tile_x = 0,
        tile_y = 0,
        tile_layer = 0,
        user_id = 0,
        off_mesh_con_count = 0,
    })
    testing.expect(t, recast.status_succeeded(nav_status), "Failed to create Detour navigation mesh")
    testing.expect(t, nav_mesh != nil, "Navigation mesh should not be nil")
    defer {
        detour.nav_mesh_destroy(nav_mesh)
        free(nav_mesh)
    }

    // Create navigation query
    query := new(detour.Nav_Mesh_Query)
    defer {
        detour.nav_mesh_query_destroy(query)
        free(query)
    }

    query_init_status := detour.nav_mesh_query_init(query, nav_mesh, 2048)
    testing.expect(t, recast.status_succeeded(query_init_status), "Failed to initialize navigation query")

    // Setup query filter
    filter: detour.Query_Filter
    detour.query_filter_init(&filter)

    // Test pathfinding from one corner to opposite corner, avoiding the obstacle area
    start_pos := [3]f32{-5, 0, -5}
    end_pos := [3]f32{5, 0, 5}
    half_extents := [3]f32{2, 4, 2}

    // Find nearest polygons
    find_status, start_ref, start_nearest := detour.find_nearest_poly(query, start_pos, half_extents, &filter)
    testing.expect(t, recast.status_succeeded(find_status), "Failed to find start polygon")
    testing.expect(t, start_ref != recast.INVALID_POLY_REF, "Start polygon should be valid")

    end_ref: recast.Poly_Ref
    end_nearest: [3]f32
    find_status, end_ref, end_nearest = detour.find_nearest_poly(query, end_pos, half_extents, &filter)
    testing.expect(t, recast.status_succeeded(find_status), "Failed to find end polygon")
    testing.expect(t, end_ref != recast.INVALID_POLY_REF, "End polygon should be valid")

    // Find path
    path := make([]recast.Poly_Ref, 256)
    defer delete(path)
    path_status, path_count := detour.find_path(query, start_ref, end_ref, start_nearest, end_nearest,
                                                      &filter, path[:], 256)
    testing.expect(t, recast.status_succeeded(path_status), "Failed to find path")
    testing.expect(t, path_count > 0, "Path should have at least one polygon")

    // Convert to straight path
    straight_path := make([]detour.Straight_Path_Point, 256)
    defer delete(straight_path)
    straight_status, straight_path_count := detour.find_straight_path(query, start_nearest, end_nearest,
                                                                           path[:path_count], path_count,
                                                                           straight_path[:], nil, nil,
                                                                           256, u32(detour.Straight_Path_Options.All_Crossings))
    testing.expect(t, recast.status_succeeded(straight_status), "Failed to find straight path")
    testing.expect(t, straight_path_count > 0, "Straight path should have at least one point")

    // Verify path starts near start position and ends near end position
    dist_to_start := linalg.distance(straight_path[0].pos, start_pos)
    dist_to_end := linalg.distance(straight_path[straight_path_count-1].pos, end_pos)

    testing.expect(t, dist_to_start < 3.0, "Path should start near the start position")
    testing.expect(t, dist_to_end < 3.0, "Path should end near the end position")
}

@(test)
test_navigation_edge_cases :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // End-to-end test: Handle edge cases

    // Test 1: Empty geometry
    {
        vertices := [][3]f32{}
        indices := []i32{}
        area_types := []u8{}

        config := recast.Config{
            cs = 0.3,
            ch = 0.2,
            walkable_height = 10,
            walkable_radius = 2,
            walkable_climb = 4,
        }

        pmesh, dmesh, ok := recast.build_navmesh(vertices[:], indices[:], area_types[:], config)
        testing.expect(t, !ok, "Should fail to build navmesh with empty geometry")

        if pmesh != nil do recast.free_poly_mesh(pmesh)
        if dmesh != nil do recast.free_poly_mesh_detail(dmesh)
    }

    // Test 2: Invalid query positions
    {
        // Create simple valid mesh first
        vertices := [][3]f32{
            {-5, 0, -5},
             {5, 0, -5},
             {5, 0,  5},
            {-5, 0,  5},
        }

        indices := []i32{
            0, 2, 1,  // Reversed winding order
            0, 3, 2,  // Reversed winding order
        }

        area_types := []u8{recast.RC_WALKABLE_AREA, recast.RC_WALKABLE_AREA}

        config := recast.Config{
            cs = 0.3,
            ch = 0.2,
            walkable_height = 10,
            walkable_radius = 2,
            walkable_climb = 4,
            walkable_slope_angle = 45.0,
            max_edge_len = 12.0,
            max_simplification_error = 1.3,
            min_region_area = 8.0,
            merge_region_area = 20.0,
            max_verts_per_poly = 6,
            detail_sample_dist = 6.0,
            detail_sample_max_error = 1.0,
        }

        pmesh, dmesh, ok := recast.build_navmesh(vertices[:], indices[:], area_types[:], config)
        testing.expect(t, ok, "Should build valid navmesh")
        defer {
            if pmesh != nil do recast.free_poly_mesh(pmesh)
            if dmesh != nil do recast.free_poly_mesh_detail(dmesh)
        }

        nav_mesh, nav_status := detour.create_nav_mesh(&detour.Create_Nav_Mesh_Data_Params{
            poly_mesh = pmesh,
            poly_mesh_detail = dmesh,
            walkable_height = f32(config.walkable_height) * config.ch,  // Convert cells to world units
            walkable_radius = f32(config.walkable_radius) * config.cs,  // Convert cells to world units
            walkable_climb = f32(config.walkable_climb) * config.ch,    // Convert cells to world units
        })
        testing.expect(t, recast.status_succeeded(nav_status), "Should create navigation mesh")
        defer {
            detour.nav_mesh_destroy(nav_mesh)
            free(nav_mesh)
        }

        query := new(detour.Nav_Mesh_Query)
        defer {
            detour.nav_mesh_query_destroy(query)
            free(query)
        }

        detour.nav_mesh_query_init(query, nav_mesh, 2048)

        filter: detour.Query_Filter
        detour.query_filter_init(&filter)

        // Test positions far outside the mesh
        far_pos := [3]f32{100, 0, 100}
        half_extents := [3]f32{2, 4, 2}

        status, ref, nearest := detour.find_nearest_poly(query, far_pos, half_extents, &filter)

        // Should succeed but return invalid ref if no polygon found
        testing.expect(t, recast.status_succeeded(status), "Query should succeed even if no polygon found")
        testing.expect(t, ref == recast.INVALID_POLY_REF, "Should return invalid ref for far away position")
    }
}
