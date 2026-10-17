#+build !js
#+private
package detour

import "core:log"
import "base:runtime"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"

@(test)
test_detour_basic_types :: proc(t: ^testing.T) {
  // Test polygon creation and manipulation
  poly: Poly
  poly_set_area(&poly, 5)
  testing.expect_value(t, poly_get_area(&poly), 5)
  poly_set_type(&poly, DT_POLYTYPE_GROUND)
  testing.expect_value(
    t,
    poly_get_type(&poly),
    DT_POLYTYPE_GROUND,
  )
  poly_set_type(&poly, DT_POLYTYPE_OFFMESH_CONNECTION)
  testing.expect_value(
    t,
    poly_get_type(&poly),
    DT_POLYTYPE_OFFMESH_CONNECTION,
  )
  // Test query filter
  filter: Query_Filter
  query_filter_init(&filter)
  testing.expect_value(t, filter.include_flags, 0xffff)
  testing.expect_value(t, filter.exclude_flags, 0)
  testing.expect_value(t, filter.area_cost[0], 1.0)
  testing.expect_value(t, filter.area_cost[DT_MAX_AREAS - 1], 1.0)
}

@(test)
test_detour_navmesh_init :: proc(t: ^testing.T) {
  nav_mesh: Nav_Mesh
  defer nav_mesh_destroy(&nav_mesh)
  params := Nav_Mesh_Params {
    orig        = {0, 0, 0},
    tile_width  = 10.0,
    tile_height = 10.0,
    max_tiles   = 64,
    max_polys   = 256,
  }
  status := nav_mesh_init(&nav_mesh, &params)
  testing.expect(
    t,
    status_succeeded(status),
    "NavMesh initialization should succeed",
  )
  testing.expect_value(t, nav_mesh.max_tiles, 64)
  testing.expect_value(t, nav_mesh.tile_width, 10.0)
  testing.expect_value(t, nav_mesh.tile_height, 10.0)
  testing.expect(t, nav_mesh.tiles != nil, "Tiles should be allocated")
  testing.expect(
    t,
    nav_mesh.pos_lookup != nil,
    "Position lookup should be allocated",
  )
}

@(test)
test_detour_reference_encoding :: proc(t: ^testing.T) {
  nav_mesh: Nav_Mesh
  defer nav_mesh_destroy(&nav_mesh)
  params := Nav_Mesh_Params {
    orig        = {0, 0, 0},
    tile_width  = 10.0,
    tile_height = 10.0,
    max_tiles   = 64,
    max_polys   = 256,
  }
  status := nav_mesh_init(&nav_mesh, &params)
  testing.expect(
    t,
    status_succeeded(status),
    "NavMesh initialization should succeed",
  )
  // Test polygon reference encoding/decoding
  salt := u32(5)
  tile_index := u32(12)
  poly_index := u32(35)
  ref := encode_poly_id(&nav_mesh, salt, tile_index, poly_index)
  decoded_salt, decoded_tile, decoded_poly := decode_poly_id(
    &nav_mesh,
    ref,
  )
  testing.expect_value(t, decoded_salt, salt)
  testing.expect_value(t, decoded_tile, tile_index)
  testing.expect_value(t, decoded_poly, poly_index)
}

@(test)
test_detour_pathfinding_context :: proc(t: ^testing.T) {
  ctx: Pathfinding_Context
  defer pathfinding_context_destroy(&ctx)
  status := pathfinding_context_init(&ctx, 16)
  testing.expect(
    t,
    status_succeeded(status),
    "Pathfinding context initialization should succeed",
  )
  // Test node creation
  ref1 := Poly_Ref(100)
  node1 := create_node(&ctx, ref1)
  testing.expect(t, node1 != nil, "Node creation should succeed")
  testing.expect_value(t, node1.id, ref1)
  // Test node retrieval
  retrieved := get_node(&ctx, ref1)
  testing.expect(
    t,
    retrieved == node1,
    "Retrieved node should match created node",
  )
  // Test duplicate creation (should return existing)
  node1_dup := create_node(&ctx, ref1)
  testing.expect(
    t,
    node1_dup != nil,
    "Duplicate node creation should not fail",
  )
  // Test context clearing
  pathfinding_context_clear(&ctx)
  cleared := get_node(&ctx, ref1)
  testing.expect(t, cleared == nil, "Node should not exist after clearing")
}

@(test)
test_detour_node_queue :: proc(t: ^testing.T) {
  ctx: Pathfinding_Context
  defer pathfinding_context_destroy(&ctx)
  queue: Node_Queue
  defer node_queue_destroy(&queue)
  pathfinding_context_init(&ctx, 16)
  node_queue_init(&queue, 16)
  // Create nodes with different costs
  ref1 := Poly_Ref(100)
  ref2 := Poly_Ref(200)
  ref3 := Poly_Ref(300)
  node1 := create_node(&ctx, ref1)
  node2 := create_node(&ctx, ref2)
  node3 := create_node(&ctx, ref3)
  node1.total = 10.0
  node2.total = 5.0
  node3.total = 15.0
  // Test queue operations
  testing.expect(
    t,
    node_queue_empty(&queue),
    "Queue should start empty",
  )
  node_queue_push(&queue, {ref1, node1.cost, node1.total})
  node_queue_push(&queue, {ref2, node2.cost, node2.total})
  node_queue_push(&queue, {ref3, node3.cost, node3.total})
  testing.expect(
    t,
    !node_queue_empty(&queue),
    "Queue should not be empty",
  )
  // Should pop in order of lowest total cost first
  first := node_queue_pop(&queue)
  testing.expect_value(t, first.ref, ref2) // node2 has lowest total (5.0)
  second := node_queue_pop(&queue)
  testing.expect_value(t, second.ref, ref1) // node1 has second lowest total (10.0)
  third := node_queue_pop(&queue)
  testing.expect_value(t, third.ref, ref3) // node3 has highest total (15.0)
}

@(test)
test_detour_node_queue_comprehensive :: proc(t: ^testing.T) {
  // Test multiple scenarios to ensure priority queue works correctly
  ctx: Pathfinding_Context
  defer pathfinding_context_destroy(&ctx)
  queue: Node_Queue
  defer node_queue_destroy(&queue)
  pathfinding_context_init(&ctx, 32)
  node_queue_init(&queue, 32)
  // Test 1: Insert in ascending order, should pop in same order
  {
    refs := []Poly_Ref{1, 2, 3, 4, 5}
    costs := []f32{1.0, 2.0, 3.0, 4.0, 5.0}
    for i in 0 ..< len(refs) {
      node := create_node(&ctx, refs[i])
      node.total = costs[i]
      node_queue_push(&queue, {refs[i], node.cost, node.total})
    }
    for i in 0 ..< len(refs) {
      popped := node_queue_pop(&queue)
      testing.expect_value(t, popped.ref, refs[i])
    }
    pathfinding_context_clear(&ctx)
  }
  // Test 2: Insert in descending order, should pop in ascending cost order
  {
    refs := []Poly_Ref{10, 11, 12, 13, 14}
    costs := []f32{10.0, 8.0, 6.0, 4.0, 2.0}
    expected_order := []Poly_Ref{14, 13, 12, 11, 10}
    for i in 0 ..< len(refs) {
      node := create_node(&ctx, refs[i])
      node.total = costs[i]
      node_queue_push(&queue, {refs[i], node.cost, node.total})
    }
    for i in 0 ..< len(expected_order) {
      popped := node_queue_pop(&queue)
      testing.expect_value(t, popped.ref, expected_order[i])
    }
    pathfinding_context_clear(&ctx)
  }
  // Test 3: Insert in random order, should pop in cost order
  {
    refs := []Poly_Ref{20, 21, 22, 23, 24}
    costs := []f32{3.5, 1.2, 4.8, 2.1, 3.9}
    expected_order := []Poly_Ref{21, 23, 20, 24, 22} // sorted by cost: 1.2, 2.1, 3.5, 3.9, 4.8
    for i in 0 ..< len(refs) {
      node := create_node(&ctx, refs[i])
      node.total = costs[i]
      node_queue_push(&queue, {refs[i], node.cost, node.total})
    }
    for i in 0 ..< len(expected_order) {
      popped := node_queue_pop(&queue)
      testing.expect_value(t, popped.ref, expected_order[i])
    }
  }
}

@(test)
test_detour_node_queue_exact_problem :: proc(t: ^testing.T) {
  // Test the exact scenario described in the issue
  ctx: Pathfinding_Context
  defer pathfinding_context_destroy(&ctx)
  queue: Node_Queue
  defer node_queue_destroy(&queue)
  pathfinding_context_init(&ctx, 16)
  node_queue_init(&queue, 16)
  // Create nodes with the exact same configuration as the original failing test
  node1_ref := Poly_Ref(100)
  node2_ref := Poly_Ref(200)
  node3_ref := Poly_Ref(300)
  node1 := create_node(&ctx, node1_ref)
  node2 := create_node(&ctx, node2_ref)
  node3 := create_node(&ctx, node3_ref)
  // Set the exact same costs as described
  node1.total = 10.0
  node2.total = 5.0 // This should be popped first (lowest cost)
  node3.total = 15.0
  // Push in the same order as the original test
  node_queue_push(&queue, {node1_ref, node1.cost, node1.total})
  node_queue_push(&queue, {node2_ref, node2.cost, node2.total})
  node_queue_push(&queue, {node3_ref, node3.cost, node3.total})
  // The first popped should be node2 (ref=200) with cost 5.0
  first := node_queue_pop(&queue)
  if first.ref != node2_ref {
    testing.fail_now(
      t,
      "Priority queue test failed - expected node2 (200) first but got node1 (100)",
    )
  }
  testing.expect_value(t, first.ref, node2_ref)
}
