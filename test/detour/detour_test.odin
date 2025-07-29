package test_detour

import "core:testing"
import "core:time"
import "core:math"
import "core:math/linalg"
import "core:log"
import nav_recast "../../mjolnir/navigation/recast"
import nav_detour "../../mjolnir/navigation/detour"
import nav "../../mjolnir/navigation"


@(test)
test_detour_basic_types :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test polygon creation and manipulation
    poly := nav_detour.Dt_Poly{}
    
    nav_detour.dt_poly_set_area(&poly, 5)
    testing.expect_value(t, nav_detour.dt_poly_get_area(&poly), 5)
    
    nav_detour.dt_poly_set_type(&poly, nav_recast.DT_POLYTYPE_GROUND)
    testing.expect_value(t, nav_detour.dt_poly_get_type(&poly), nav_recast.DT_POLYTYPE_GROUND)
    
    nav_detour.dt_poly_set_type(&poly, nav_recast.DT_POLYTYPE_OFFMESH_CONNECTION)
    testing.expect_value(t, nav_detour.dt_poly_get_type(&poly), nav_recast.DT_POLYTYPE_OFFMESH_CONNECTION)
    
    // Test query filter
    filter := nav_detour.Dt_Query_Filter{}
    nav_detour.dt_query_filter_init(&filter)
    
    testing.expect_value(t, filter.include_flags, 0xffff)
    testing.expect_value(t, filter.exclude_flags, 0)
    testing.expect_value(t, filter.area_cost[0], 1.0)
    testing.expect_value(t, filter.area_cost[nav_recast.DT_MAX_AREAS - 1], 1.0)
}

@(test)
test_detour_navmesh_init :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := nav_detour.Dt_Nav_Mesh{}
    defer nav_detour.dt_nav_mesh_destroy(&nav_mesh)
    
    params := nav_detour.Dt_Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = 10.0,
        tile_height = 10.0,
        max_tiles = 64,
        max_polys = 256,
    }
    
    status := nav_detour.dt_nav_mesh_init(&nav_mesh, &params)
    testing.expect(t, nav_recast.status_succeeded(status), "NavMesh initialization should succeed")
    
    testing.expect_value(t, nav_mesh.max_tiles, 64)
    testing.expect_value(t, nav_mesh.tile_width, 10.0)
    testing.expect_value(t, nav_mesh.tile_height, 10.0)
    testing.expect(t, nav_mesh.tiles != nil, "Tiles should be allocated")
    testing.expect(t, nav_mesh.pos_lookup != nil, "Position lookup should be allocated")
}

@(test)
test_detour_reference_encoding :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    nav_mesh := nav_detour.Dt_Nav_Mesh{}
    defer nav_detour.dt_nav_mesh_destroy(&nav_mesh)
    
    params := nav_detour.Dt_Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = 10.0,
        tile_height = 10.0,
        max_tiles = 64,
        max_polys = 256,
    }
    
    status := nav_detour.dt_nav_mesh_init(&nav_mesh, &params)
    testing.expect(t, nav_recast.status_succeeded(status), "NavMesh initialization should succeed")
    
    // Test polygon reference encoding/decoding
    salt := u32(5)
    tile_index := u32(12)
    poly_index := u32(35)
    
    ref := nav_detour.dt_encode_poly_id(&nav_mesh, salt, tile_index, poly_index)
    decoded_salt, decoded_tile, decoded_poly := nav_detour.dt_decode_poly_id(&nav_mesh, ref)
    
    testing.expect_value(t, decoded_salt, salt)
    testing.expect_value(t, decoded_tile, tile_index)
    testing.expect_value(t, decoded_poly, poly_index)
}

@(test)
test_detour_node_pool :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    pool := nav_detour.Dt_Node_Pool{}
    defer nav_detour.dt_node_pool_destroy(&pool)
    
    status := nav_detour.dt_node_pool_init(&pool, 16)
    testing.expect(t, nav_recast.status_succeeded(status), "Node pool initialization should succeed")
    
    // Test node creation
    ref1 := nav_recast.Poly_Ref(100)
    node1 := nav_detour.dt_node_pool_create_node(&pool, ref1)
    testing.expect(t, node1 != nil, "Node creation should succeed")
    testing.expect_value(t, node1.id, ref1)
    
    // Test node retrieval
    retrieved := nav_detour.dt_node_pool_get_node(&pool, ref1)
    testing.expect(t, retrieved == node1, "Retrieved node should match created node")
    
    // Test duplicate creation (should return existing)
    node1_dup := nav_detour.dt_node_pool_create_node(&pool, ref1)
    testing.expect(t, node1_dup != nil, "Duplicate node creation should not fail")
    
    // Test pool clearing
    nav_detour.dt_node_pool_clear(&pool)
    cleared := nav_detour.dt_node_pool_get_node(&pool, ref1)
    testing.expect(t, cleared == nil, "Node should not exist after clearing")
}

@(test)
test_detour_node_queue :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    pool := nav_detour.Dt_Node_Pool{}
    defer nav_detour.dt_node_pool_destroy(&pool)
    
    queue := nav_detour.Dt_Node_Queue{}
    defer nav_detour.dt_node_queue_destroy(&queue)
    
    nav_detour.dt_node_pool_init(&pool, 16)
    nav_detour.dt_node_queue_init(&queue, &pool, 16)
    
    // Create nodes with different costs
    ref1 := nav_recast.Poly_Ref(100)
    ref2 := nav_recast.Poly_Ref(200)
    ref3 := nav_recast.Poly_Ref(300)
    
    node1 := nav_detour.dt_node_pool_create_node(&pool, ref1)
    node2 := nav_detour.dt_node_pool_create_node(&pool, ref2)
    node3 := nav_detour.dt_node_pool_create_node(&pool, ref3)
    
    node1.total = 10.0
    node2.total = 5.0
    node3.total = 15.0
    
    // Test queue operations
    testing.expect(t, nav_detour.dt_node_queue_empty(&queue), "Queue should start empty")
    
    nav_detour.dt_node_queue_push(&queue, {ref1, node1.cost, node1.total})
    nav_detour.dt_node_queue_push(&queue, {ref2, node2.cost, node2.total})
    nav_detour.dt_node_queue_push(&queue, {ref3, node3.cost, node3.total})
    
    testing.expect(t, !nav_detour.dt_node_queue_empty(&queue), "Queue should not be empty")
    
    // Should pop in order of lowest total cost first
    first := nav_detour.dt_node_queue_pop(&queue)
    testing.expect_value(t, first.ref, ref2) // node2 has lowest total (5.0)
    
    second := nav_detour.dt_node_queue_pop(&queue)
    testing.expect_value(t, second.ref, ref1) // node1 has second lowest total (10.0)
    
    third := nav_detour.dt_node_queue_pop(&queue)
    testing.expect_value(t, third.ref, ref3) // node3 has highest total (15.0)
}

@(test)
test_detour_node_queue_comprehensive :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test multiple scenarios to ensure priority queue works correctly
    pool := nav_detour.Dt_Node_Pool{}
    defer nav_detour.dt_node_pool_destroy(&pool)
    
    queue := nav_detour.Dt_Node_Queue{}
    defer nav_detour.dt_node_queue_destroy(&queue)
    
    nav_detour.dt_node_pool_init(&pool, 32)
    nav_detour.dt_node_queue_init(&queue, &pool, 32)
    
    // Test 1: Insert in ascending order, should pop in same order
    {
        refs := []nav_recast.Poly_Ref{1, 2, 3, 4, 5}
        costs := []f32{1.0, 2.0, 3.0, 4.0, 5.0}
        
        for i in 0..<len(refs) {
            node := nav_detour.dt_node_pool_create_node(&pool, refs[i])
            node.total = costs[i]
            nav_detour.dt_node_queue_push(&queue, {refs[i], node.cost, node.total})
        }
        
        for i in 0..<len(refs) {
            popped := nav_detour.dt_node_queue_pop(&queue)
            testing.expect_value(t, popped.ref, refs[i])
        }
        
        nav_detour.dt_node_pool_clear(&pool)
    }
    
    // Test 2: Insert in descending order, should pop in ascending cost order
    {
        refs := []nav_recast.Poly_Ref{10, 11, 12, 13, 14} 
        costs := []f32{10.0, 8.0, 6.0, 4.0, 2.0}
        expected_order := []nav_recast.Poly_Ref{14, 13, 12, 11, 10}
        
        for i in 0..<len(refs) {
            node := nav_detour.dt_node_pool_create_node(&pool, refs[i])
            node.total = costs[i]
            nav_detour.dt_node_queue_push(&queue, {refs[i], node.cost, node.total})
        }
        
        for i in 0..<len(expected_order) {
            popped := nav_detour.dt_node_queue_pop(&queue)
            testing.expect_value(t, popped.ref, expected_order[i])
        }
        
        nav_detour.dt_node_pool_clear(&pool)
    }
    
    // Test 3: Insert in random order, should pop in cost order
    {
        refs := []nav_recast.Poly_Ref{20, 21, 22, 23, 24}
        costs := []f32{3.5, 1.2, 4.8, 2.1, 3.9}
        expected_order := []nav_recast.Poly_Ref{21, 23, 20, 24, 22} // sorted by cost: 1.2, 2.1, 3.5, 3.9, 4.8
        
        for i in 0..<len(refs) {
            node := nav_detour.dt_node_pool_create_node(&pool, refs[i])
            node.total = costs[i] 
            nav_detour.dt_node_queue_push(&queue, {refs[i], node.cost, node.total})
        }
        
        for i in 0..<len(expected_order) {
            popped := nav_detour.dt_node_queue_pop(&queue)
            testing.expect_value(t, popped.ref, expected_order[i])
        }
    }
}

@(test)
test_detour_node_queue_exact_problem :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Test the exact scenario described in the issue
    pool := nav_detour.Dt_Node_Pool{}
    defer nav_detour.dt_node_pool_destroy(&pool)
    
    queue := nav_detour.Dt_Node_Queue{}
    defer nav_detour.dt_node_queue_destroy(&queue)
    
    nav_detour.dt_node_pool_init(&pool, 16)
    nav_detour.dt_node_queue_init(&queue, &pool, 16)
    
    // Create nodes with the exact same configuration as the original failing test
    node1_ref := nav_recast.Poly_Ref(100)
    node2_ref := nav_recast.Poly_Ref(200) 
    node3_ref := nav_recast.Poly_Ref(300)
    
    node1 := nav_detour.dt_node_pool_create_node(&pool, node1_ref)
    node2 := nav_detour.dt_node_pool_create_node(&pool, node2_ref)
    node3 := nav_detour.dt_node_pool_create_node(&pool, node3_ref)
    
    // Set the exact same costs as described
    node1.total = 10.0
    node2.total = 5.0  // This should be popped first (lowest cost)
    node3.total = 15.0
    
    // Push in the same order as the original test
    nav_detour.dt_node_queue_push(&queue, {node1_ref, node1.cost, node1.total})
    nav_detour.dt_node_queue_push(&queue, {node2_ref, node2.cost, node2.total})
    nav_detour.dt_node_queue_push(&queue, {node3_ref, node3.cost, node3.total})
    
    // The first popped should be node2 (ref=200) with cost 5.0
    first := nav_detour.dt_node_queue_pop(&queue)  
    if first.ref != node2_ref {
        testing.fail_now(t, "Priority queue test failed - expected node2 (200) first but got node1 (100)")
    }
    
    testing.expect_value(t, first.ref, node2_ref)
}

// End-to-end test using the priority queue in real pathfinding scenarios
@(test)
test_detour_end_to_end_pathfinding :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Initialize navigation memory system
    nav.nav_memory_init()
    defer nav.nav_memory_shutdown()
    
    // Test the complete pipeline: create nav mesh -> find path -> verify priority queue behavior
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    query := nav_detour.Dt_Nav_Mesh_Query{}
    defer nav_detour.dt_nav_mesh_query_destroy(&query)
    
    status := nav_detour.dt_nav_mesh_query_init(&query, nav_mesh, 512)
    testing.expect(t, nav_recast.status_succeeded(status), "Query initialization should succeed")
    
    filter := nav_detour.Dt_Query_Filter{}
    nav_detour.dt_query_filter_init(&filter)
    
    // Test multiple paths to verify consistent priority queue behavior
    test_cases := []struct {
        start_pos: [3]f32,
        end_pos:   [3]f32,
        description: string,
    }{
        {{1.0, 0.0, 1.0}, {9.0, 0.0, 9.0}, "Corner to corner path"},
        {{5.0, 0.0, 1.0}, {5.0, 0.0, 9.0}, "Straight path"},
        {{1.0, 0.0, 5.0}, {9.0, 0.0, 5.0}, "Horizontal path"},
        {{2.0, 0.0, 2.0}, {8.0, 0.0, 8.0}, "Diagonal path"},
    }
    
    half_extents := [3]f32{1.0, 1.0, 1.0}
    
    for test_case, idx in test_cases {
        // For each test case, verify pathfinding works correctly
        start_ref := nav_recast.Poly_Ref(0)
        start_nearest := [3]f32{}
        status = nav_detour.dt_find_nearest_poly(&query, test_case.start_pos, half_extents, &filter, &start_ref, &start_nearest)
        testing.expect(t, nav_recast.status_succeeded(status), "Should find start polygon")
        
        end_ref := nav_recast.Poly_Ref(0)
        end_nearest := [3]f32{}
        status = nav_detour.dt_find_nearest_poly(&query, test_case.end_pos, half_extents, &filter, &end_ref, &end_nearest)
        testing.expect(t, nav_recast.status_succeeded(status), "Should find end polygon")
        
        if start_ref == nav_recast.INVALID_POLY_REF || end_ref == nav_recast.INVALID_POLY_REF {
            continue  // Skip if can't find valid polygons
        }
        
        // Find path using the priority queue
        path := make([]nav_recast.Poly_Ref, 128)
        defer delete(path)
        
        path_count := i32(0)
        status = nav_detour.dt_find_path(&query, start_ref, end_ref, start_nearest, end_nearest,
                                        &filter, path, &path_count, 128)
        testing.expect(t, nav_recast.status_succeeded(status), "Pathfinding should succeed")
        testing.expect(t, path_count > 0, "Path should contain at least one polygon")
        
        // Verify path starts with start polygon
        testing.expect_value(t, path[0], start_ref)
        
        // Generate straight path to further test the system
        straight_path := make([]nav_detour.Dt_Straight_Path_Point, 32)
        defer delete(straight_path)
        
        straight_path_flags := make([]u8, 32)
        defer delete(straight_path_flags)
        
        straight_path_refs := make([]nav_recast.Poly_Ref, 32)
        defer delete(straight_path_refs)
        
        straight_path_count := i32(0)
        
        status = nav_detour.dt_find_straight_path(&query, start_nearest, end_nearest, path, path_count,
                                                 straight_path, straight_path_flags, straight_path_refs,
                                                 &straight_path_count, 32, 0)
        testing.expect(t, nav_recast.status_succeeded(status), "Straight path should succeed")
        testing.expect(t, straight_path_count >= 2, "Should have at least start and end points")
        
        // Verify the path makes geometric sense
        start_dist := linalg.distance(straight_path[0].pos, start_nearest)
        end_dist := linalg.distance(straight_path[straight_path_count - 1].pos, end_nearest)
        testing.expect(t, start_dist < 2.0, "Path should start near requested start")
        testing.expect(t, end_dist < 2.0, "Path should end near requested end")
    }
}

@(test)
test_detour_spatial_queries :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Initialize navigation memory system
    nav.nav_memory_init()
    defer nav.nav_memory_shutdown()
    
    // Create a simple test navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    query := nav_detour.Dt_Nav_Mesh_Query{}
    defer nav_detour.dt_nav_mesh_query_destroy(&query)
    
    status := nav_detour.dt_nav_mesh_query_init(&query, nav_mesh, 256)
    testing.expect(t, nav_recast.status_succeeded(status), "Query initialization should succeed")
    
    filter := nav_detour.Dt_Query_Filter{}
    nav_detour.dt_query_filter_init(&filter)
    
    // Test find nearest polygon
    center := [3]f32{5.0, 0.0, 5.0}
    half_extents := [3]f32{2.0, 1.0, 2.0}
    
    nearest_ref := nav_recast.Poly_Ref(0)
    nearest_pt := [3]f32{}
    
    status = nav_detour.dt_find_nearest_poly(&query, center, half_extents, &filter, &nearest_ref, &nearest_pt)
    testing.expect(t, nav_recast.status_succeeded(status), "Find nearest poly should succeed")
    
    // Test query polygons
    polys := make([]nav_recast.Poly_Ref, 16)
    defer delete(polys)
    
    poly_count := i32(0)
    status = nav_detour.dt_query_polygons(&query, center, half_extents, &filter, polys, &poly_count, 16)
    testing.expect(t, nav_recast.status_succeeded(status), "Query polygons should succeed")
}

@(test)
test_detour_pathfinding :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Initialize navigation memory system
    nav.nav_memory_init()
    defer nav.nav_memory_shutdown()
    
    // Create a simple test navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    query := nav_detour.Dt_Nav_Mesh_Query{}
    defer nav_detour.dt_nav_mesh_query_destroy(&query)
    
    status := nav_detour.dt_nav_mesh_query_init(&query, nav_mesh, 256)
    testing.expect(t, nav_recast.status_succeeded(status), "Query initialization should succeed")
    
    filter := nav_detour.Dt_Query_Filter{}
    nav_detour.dt_query_filter_init(&filter)
    
    // Find start and end polygons
    start_pos := [3]f32{1.0, 0.0, 1.0}
    end_pos := [3]f32{9.0, 0.0, 9.0}
    half_extents := [3]f32{1.0, 1.0, 1.0}
    
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    status = nav_detour.dt_find_nearest_poly(&query, start_pos, half_extents, &filter, &start_ref, &start_nearest)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find start polygon")
    testing.expect(t, start_ref != nav_recast.INVALID_POLY_REF, "Start reference should be valid")
    
    end_ref := nav_recast.Poly_Ref(0)
    end_nearest := [3]f32{}
    status = nav_detour.dt_find_nearest_poly(&query, end_pos, half_extents, &filter, &end_ref, &end_nearest)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find end polygon")
    testing.expect(t, end_ref != nav_recast.INVALID_POLY_REF, "End reference should be valid")
    
    // Test pathfinding
    path := make([]nav_recast.Poly_Ref, 64)
    defer delete(path)
    
    path_count := i32(0)
    status = nav_detour.dt_find_path(&query, start_ref, end_ref, start_nearest, end_nearest, 
                                    &filter, path, &path_count, 64)
    testing.expect(t, nav_recast.status_succeeded(status), "Pathfinding should succeed")
    testing.expect(t, path_count > 0, "Path should contain at least one polygon")
    testing.expect_value(t, path[0], start_ref)
}

@(test)
test_detour_straight_path :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Initialize navigation memory system
    nav.nav_memory_init()
    defer nav.nav_memory_shutdown()
    
    // Create a simple test navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    query := nav_detour.Dt_Nav_Mesh_Query{}
    defer nav_detour.dt_nav_mesh_query_destroy(&query)
    
    status := nav_detour.dt_nav_mesh_query_init(&query, nav_mesh, 256)
    testing.expect(t, nav_recast.status_succeeded(status), "Query initialization should succeed")
    
    filter := nav_detour.Dt_Query_Filter{}
    nav_detour.dt_query_filter_init(&filter)
    
    // Find valid polygon references first
    start_pos := [3]f32{5.0, 0.0, 5.0}  // Center of the test quad
    end_pos := [3]f32{8.0, 0.0, 8.0}    // Near the center
    
    extents := [3]f32{1.0, 1.0, 1.0}
    
    start_ref := nav_recast.INVALID_POLY_REF
    start_nearest := [3]f32{}
    start_status := nav_detour.dt_find_nearest_poly(&query, start_pos, extents, &filter, &start_ref, &start_nearest)
    testing.expect(t, nav_recast.status_succeeded(start_status), "Should find start polygon")
    testing.expect(t, start_ref != nav_recast.INVALID_POLY_REF, "Should have valid start reference")
    
    // Use a simple single-polygon path for testing straight path
    path := []nav_recast.Poly_Ref{start_ref}
    
    straight_path := make([]nav_detour.Dt_Straight_Path_Point, 16)
    defer delete(straight_path)
    
    straight_path_flags := make([]u8, 16)
    defer delete(straight_path_flags)
    
    straight_path_refs := make([]nav_recast.Poly_Ref, 16)
    defer delete(straight_path_refs)
    
    straight_path_count := i32(0)
    
    status = nav_detour.dt_find_straight_path(&query, start_nearest, end_pos, path, i32(len(path)),
                                             straight_path, straight_path_flags, straight_path_refs,
                                             &straight_path_count, 16, 0)
    
    
    testing.expect(t, nav_recast.status_succeeded(status), "Straight path should succeed")
    testing.expect(t, straight_path_count >= 1, "Should have at least start point")
}

@(test)
test_detour_raycast :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Initialize navigation memory system
    nav.nav_memory_init()
    defer nav.nav_memory_shutdown()
    
    // Create a simple test navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    query := nav_detour.Dt_Nav_Mesh_Query{}
    defer nav_detour.dt_nav_mesh_query_destroy(&query)
    
    status := nav_detour.dt_nav_mesh_query_init(&query, nav_mesh, 256)
    testing.expect(t, nav_recast.status_succeeded(status), "Query initialization should succeed")
    
    filter := nav_detour.Dt_Query_Filter{}
    nav_detour.dt_query_filter_init(&filter)
    
    start_pos := [3]f32{1.0, 0.0, 1.0}
    end_pos := [3]f32{9.0, 0.0, 9.0}
    half_extents := [3]f32{1.0, 1.0, 1.0}
    
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    status = nav_detour.dt_find_nearest_poly(&query, start_pos, half_extents, &filter, &start_ref, &start_nearest)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find start polygon")
    
    hit := nav_detour.Dt_Raycast_Hit{}
    path := make([]nav_recast.Poly_Ref, 32)
    defer delete(path)
    
    path_count := i32(0)
    
    status = nav_detour.dt_raycast(&query, start_ref, start_nearest, end_pos, &filter, 0,
                                  &hit, path, &path_count, 32)
    testing.expect(t, nav_recast.status_succeeded(status), "Raycast should succeed")
    testing.expect(t, hit.t >= 0.0, "Hit parameter should be non-negative")
}

@(test)
test_detour_move_along_surface :: proc(t: ^testing.T) {
    testing.set_fail_timeout(t, 30 * time.Second)
    
    // Initialize navigation memory system
    nav.nav_memory_init()
    defer nav.nav_memory_shutdown()
    
    // Create a simple test navigation mesh
    nav_mesh := create_test_nav_mesh(t)
    defer destroy_test_nav_mesh(nav_mesh)
    
    query := nav_detour.Dt_Nav_Mesh_Query{}
    defer nav_detour.dt_nav_mesh_query_destroy(&query)
    
    status := nav_detour.dt_nav_mesh_query_init(&query, nav_mesh, 256)
    testing.expect(t, nav_recast.status_succeeded(status), "Query initialization should succeed")
    
    filter := nav_detour.Dt_Query_Filter{}
    nav_detour.dt_query_filter_init(&filter)
    
    start_pos := [3]f32{5.0, 0.0, 5.0}
    end_pos := [3]f32{7.0, 0.0, 7.0}
    half_extents := [3]f32{1.0, 1.0, 1.0}
    
    start_ref := nav_recast.Poly_Ref(0)
    start_nearest := [3]f32{}
    status = nav_detour.dt_find_nearest_poly(&query, start_pos, half_extents, &filter, &start_ref, &start_nearest)
    testing.expect(t, nav_recast.status_succeeded(status), "Should find start polygon")
    
    result_pos := [3]f32{}
    visited := make([]nav_recast.Poly_Ref, 16)
    defer delete(visited)
    
    visited_count := i32(0)
    
    status = nav_detour.dt_move_along_surface(&query, start_ref, start_nearest, end_pos, &filter,
                                             &result_pos, visited, &visited_count, 16)
    testing.expect(t, nav_recast.status_succeeded(status), "Move along surface should succeed")
    testing.expect(t, visited_count > 0, "Should visit at least one polygon")
}

// Helper function to create a simple test navigation mesh
create_test_nav_mesh :: proc(t: ^testing.T) -> ^nav_detour.Dt_Nav_Mesh {
    // Create a simple 10x10 quad navigation mesh for testing
    nav_mesh := new(nav_detour.Dt_Nav_Mesh)
    
    params := nav_detour.Dt_Nav_Mesh_Params{
        orig = {0, 0, 0},
        tile_width = 10.0,
        tile_height = 10.0,
        max_tiles = 1,
        max_polys = 64,
    }
    
    status := nav_detour.dt_nav_mesh_init(nav_mesh, &params)
    if nav_recast.status_failed(status) {
        testing.fail_now(t, "Failed to initialize test navigation mesh")
    }
    
    // Create simple test tile data
    data := create_simple_tile_data()
    
    _, add_status := nav_detour.dt_nav_mesh_add_tile(nav_mesh, data, nav_recast.DT_TILE_FREE_DATA)
    if nav_recast.status_failed(add_status) {
        testing.fail_now(t, "Failed to add test tile to navigation mesh")
    }
    
    return nav_mesh
}

destroy_test_nav_mesh :: proc(nav_mesh: ^nav_detour.Dt_Nav_Mesh) {
    nav_detour.dt_nav_mesh_destroy(nav_mesh)
    free(nav_mesh)
}

create_simple_tile_data :: proc() -> []u8 {
    // Create minimal tile data for testing
    // This would normally come from Recast mesh processing
    
    header_size := size_of(nav_detour.Dt_Mesh_Header)
    poly_size := size_of(nav_detour.Dt_Poly) * 1  // 1 polygon
    vertex_size := size_of([3]f32) * 4  // 4 vertices
    link_size := size_of(nav_detour.Dt_Link) * 4  // 4 links for max_link_count
    
    // Memory layout must match C++ reference: Header -> Vertices -> Polygons -> Links
    total_size := header_size + vertex_size + poly_size + link_size
    data := make([]u8, total_size)
    
    // Setup header
    header := cast(^nav_detour.Dt_Mesh_Header)raw_data(data)
    header.magic = nav_recast.DT_NAVMESH_MAGIC
    header.version = nav_recast.DT_NAVMESH_VERSION
    header.x = 0
    header.y = 0
    header.layer = 0
    header.poly_count = 1
    header.vert_count = 4
    header.max_link_count = 4
    header.bmin = {0, 0, 0}
    header.bmax = {10, 1, 10}
    header.walkable_height = 2.0
    header.walkable_radius = 0.6
    header.walkable_climb = 0.9
    header.bv_quant_factor = 1.0
    
    // Setup vertices (must come first after header to match C++ reference)
    verts := cast(^[4][3]f32)(uintptr(raw_data(data)) + uintptr(header_size))
    verts[0] = [3]f32{0, 0, 0}
    verts[1] = [3]f32{10, 0, 0}
    verts[2] = [3]f32{10, 0, 10}
    verts[3] = [3]f32{0, 0, 10}
    
    // Setup polygon (must come after vertices to match C++ reference)
    poly := cast(^nav_detour.Dt_Poly)(uintptr(raw_data(data)) + uintptr(header_size) + uintptr(vertex_size))
    poly.verts[0] = 0
    poly.verts[1] = 1
    poly.verts[2] = 2
    poly.verts[3] = 3
    poly.vert_count = 4
    poly.flags = 1
    nav_detour.dt_poly_set_area(poly, nav_recast.RC_WALKABLE_AREA)
    nav_detour.dt_poly_set_type(poly, nav_recast.DT_POLYTYPE_GROUND)
    
    // Setup links (initialize to zero - will be connected during tile addition)
    links := cast(^[4]nav_detour.Dt_Link)(uintptr(raw_data(data)) + uintptr(header_size) + uintptr(vertex_size) + uintptr(poly_size))
    for i in 0..<4 {
        links[i] = nav_detour.Dt_Link{}
    }
    
    return data
}