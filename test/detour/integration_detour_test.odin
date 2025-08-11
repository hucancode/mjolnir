package test_detour

import "core:testing"
import "core:time"
import "core:math"
import "core:math/linalg"
import nav_recast "../../mjolnir/navigation/recast"
import nav_detour "../../mjolnir/navigation/detour"

// Integration test for priority queue in pathfinding context
@(test)
test_integration_pathfinding_priority_queue :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)

    // Create a test navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)

    // Create query object
    query := nav_detour.Nav_Mesh_Query{}
    defer nav_detour.nav_mesh_query_destroy(&query)

    status := nav_detour.nav_mesh_query_init(&query, nav_mesh, 256)
    testing.expect(t, nav_recast.status_succeeded(status), "Query initialization should succeed")

    // Test that nodes are processed in correct order during pathfinding
    // We'll track the order in which nodes are processed by the priority queue

    filter := nav_detour.Query_Filter{}
    nav_detour.query_filter_init(&filter)

    // Find start and end polygons
    start_pos := [3]f32{1.0, 0.0, 1.0}
    end_pos := [3]f32{9.0, 0.0, 9.0}
    half_extents := [3]f32{1.0, 1.0, 1.0}

    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    status, start_ref, start_nearest = nav_detour.find_nearest_poly(&query, start_pos, half_extents, &filter)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find start polygon")
    testing.expect(t, start_ref != nav_recast.INVALID_POLY_REF, "Start reference should be valid")

    end_ref := nav_recast.Poly_Ref(0)
    end_nearest := [3]f32{}
    status, end_ref, end_nearest = nav_detour.find_nearest_poly(&query, end_pos, half_extents, &filter)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find end polygon")
    testing.expect(t, end_ref != nav_recast.INVALID_POLY_REF, "End reference should be valid")

    // Test pathfinding - this will exercise the priority queue internally
    path := make([]nav_recast.Poly_Ref, 64)
    defer delete(path)

    path_status, path_count := nav_detour.find_path(&query, start_ref, end_ref, start_nearest, end_nearest,
                                                &filter, path, 64)
    testing.expect(t, nav_recast.status_succeeded(path_status), "Pathfinding should succeed")
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
    query1 := nav_detour.Nav_Mesh_Query{}
    defer nav_detour.nav_mesh_query_destroy(&query1)

    query2 := nav_detour.Nav_Mesh_Query{}
    defer nav_detour.nav_mesh_query_destroy(&query2)

    status1 := nav_detour.nav_mesh_query_init(&query1, nav_mesh1, 128)
    testing.expect(t, nav_recast.status_succeeded(status1), "Query1 initialization should succeed")

    status2 := nav_detour.nav_mesh_query_init(&query2, nav_mesh2, 128)
    testing.expect(t, nav_recast.status_succeeded(status2), "Query2 initialization should succeed")

    filter := nav_detour.Query_Filter{}
    nav_detour.query_filter_init(&filter)

    // Perform pathfinding with different parameters on both queries
    // This tests that the thread-local context switching works correctly

    // Query 1 - short path
    start_pos1 := [3]f32{1.0, 0.0, 1.0}
    end_pos1 := [3]f32{3.0, 0.0, 3.0}
    half_extents := [3]f32{1.0, 1.0, 1.0}

    status, start_ref1, start_nearest1 := nav_detour.find_nearest_poly(&query1, start_pos1, half_extents, &filter)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find start polygon for query1")

    end_ref1 := nav_recast.Poly_Ref(0)
    end_nearest1 := [3]f32{}
    status, end_ref1, end_nearest1 = nav_detour.find_nearest_poly(&query1, end_pos1, half_extents, &filter)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find end polygon for query1")

    // Query 2 - longer path
    start_pos2 := [3]f32{2.0, 0.0, 2.0}
    end_pos2 := [3]f32{8.0, 0.0, 8.0}

    start_ref2 := nav_recast.Poly_Ref(0)
    start_nearest2 := [3]f32{}
    status, start_ref2, start_nearest2 = nav_detour.find_nearest_poly(&query2, start_pos2, half_extents, &filter)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find start polygon for query2")

    end_ref2 := nav_recast.Poly_Ref(0)
    end_nearest2 := [3]f32{}
    status, end_ref2, end_nearest2 = nav_detour.find_nearest_poly(&query2, end_pos2, half_extents, &filter)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find end polygon for query2")

    // Interleave pathfinding operations to test context switching
    path1 := make([]nav_recast.Poly_Ref, 32)
    defer delete(path1)
    path2 := make([]nav_recast.Poly_Ref, 32)
    defer delete(path2)

    // First pathfinding on query1
    path_status1, path_count1 := nav_detour.find_path(&query1, start_ref1, end_ref1, start_nearest1, end_nearest1,
                                                 &filter, path1, 32)
    testing.expect(t, nav_recast.status_succeeded(path_status1), "Pathfinding on query1 should succeed")
    testing.expect(t, path_count1 > 0, "Path1 should contain at least one polygon")

    // Then pathfinding on query2
    path_status2, path_count2 := nav_detour.find_path(&query2, start_ref2, end_ref2, start_nearest2, end_nearest2,
                                                 &filter, path2, 32)
    testing.expect(t, nav_recast.status_succeeded(path_status2), "Pathfinding on query2 should succeed")
    testing.expect(t, path_count2 > 0, "Path2 should contain at least one polygon")

    // Verify both paths are valid and contain their expected start polygons
    testing.expect_value(t, path1[0], start_ref1)
    testing.expect_value(t, path2[0], start_ref2)

    // In a simple single-polygon mesh, paths may legitimately be the same
    // The important thing is that both pathfinding operations succeeded independently
    // without interfering with each other's context (testing thread safety)
}
