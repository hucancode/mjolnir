package tests

import "../mjolnir/geometry"
import "../mjolnir/resources"
import "../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"

// Helper to create minimal world for testing
make_test_world :: proc() -> world.World {
  w: world.World
  world.init(&w)
  return w
}

// Helper to manually insert a node entry into the octree for testing
test_insert_node :: proc(
  w: ^world.World,
  handle: resources.Handle,
  position: [3]f32,
  tags: world.NodeTagSet,
) {
  entry := world.NodeEntry {
    handle   = handle,
    position = position,
    tags     = tags,
  }
  geometry.octree_insert(&w.node_octree, entry)
}

// Unit Tests - Test with hard-coded perfect inputs

@(test)
test_aoe_insert_and_query_sphere :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  // Insert nodes at specific positions
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  h2 := resources.Handle {
    index      = 2,
    generation = 0,
  }
  h3 := resources.Handle {
    index      = 3,
    generation = 0,
  }
  test_insert_node(&w, h1, {0, 0, 0}, {.MESH})
  test_insert_node(&w, h2, {5, 0, 0}, {.SPRITE})
  test_insert_node(&w, h3, {10, 0, 0}, {.LIGHT})
  // Query sphere at origin with radius 3
  results := make([dynamic]resources.Handle)
  defer delete(results)
  world.query_sphere(&w, {0, 0, 0}, 3.0, &results)
  testing.expect(
    t,
    len(results) == 1,
    "Should find exactly 1 node within radius 3",
  )
  testing.expect(t, results[0].index == 1, "Should find node with index 1")
  // Query larger sphere
  clear(&results)
  world.query_sphere(&w, {0, 0, 0}, 8.0, &results)
  testing.expect(
    t,
    len(results) >= 2,
    "Should find at least 2 nodes within radius 8",
  )
}

@(test)
test_aoe_query_cube :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  h2 := resources.Handle {
    index      = 2,
    generation = 0,
  }
  h3 := resources.Handle {
    index      = 3,
    generation = 0,
  }
  h4 := resources.Handle {
    index      = 4,
    generation = 0,
  }
  test_insert_node(&w, h1, {0, 0, 0}, {.MESH})
  test_insert_node(&w, h2, {2, 2, 2}, {.MESH})
  test_insert_node(&w, h3, {-2, -2, -2}, {.SPRITE})
  test_insert_node(&w, h4, {10, 10, 10}, {.LIGHT})
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query cube centered at origin with half-extent 3
  world.query_cube(&w, {0, 0, 0}, {3, 3, 3}, &results)
  testing.expect(t, len(results) == 3, "Should find exactly 3 nodes in cube")
}

@(test)
test_aoe_query_disc :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  h2 := resources.Handle {
    index      = 2,
    generation = 0,
  }
  h3 := resources.Handle {
    index      = 3,
    generation = 0,
  }
  h4 := resources.Handle {
    index      = 4,
    generation = 0,
  }
  // Insert nodes on XZ plane
  test_insert_node(&w, h1, {0, 0, 0}, {.MESH})
  test_insert_node(&w, h2, {2, 0, 0}, {.MESH})
  test_insert_node(&w, h3, {0, 5, 0}, {.SPRITE}) // Above plane
  test_insert_node(&w, h4, {0, 0, 2}, {.LIGHT})
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query disc on XZ plane (Y-up normal) with radius 3
  world.query_disc(&w, {0, 0, 0}, {0, 1, 0}, 3.0, &results)
  testing.expect(
    t,
    len(results) == 3,
    "Should find 3 nodes on disc (excluding node above plane)",
  )
}

@(test)
test_aoe_query_fan :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  h2 := resources.Handle {
    index      = 2,
    generation = 0,
  }
  h3 := resources.Handle {
    index      = 3,
    generation = 0,
  }
  h4 := resources.Handle {
    index      = 4,
    generation = 0,
  }
  // Insert nodes in different directions from origin
  test_insert_node(&w, h1, {5, 0, 0}, {.MESH}) // Positive X
  test_insert_node(&w, h2, {-5, 0, 0}, {.MESH}) // Negative X
  test_insert_node(&w, h3, {0, 5, 0}, {.SPRITE}) // Positive Y
  test_insert_node(&w, h4, {3.5, 3.5, 0}, {.LIGHT}) // 45 degrees in XY
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query 90-degree fan pointing in positive X direction
  world.query_fan(
    &w,
    {0, 0, 0},
    linalg.VECTOR3F32_X_AXIS,
    8.0,
    math.PI / 2,
    &results,
  )
  testing.expect(
    t,
    len(results) >= 1,
    "Should find at least node in positive X direction",
  )
  // Verify it doesn't include node in negative X
  found_negative_x := false
  for handle in results {
    if handle.index == 2 do found_negative_x = true
  }
  testing.expect(
    t,
    !found_negative_x,
    "Should not find node in opposite direction",
  )
}

// Integration Tests - Test tag filtering

@(test)
test_aoe_tag_filtering_any :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  h2 := resources.Handle {
    index      = 2,
    generation = 0,
  }
  h3 := resources.Handle {
    index      = 3,
    generation = 0,
  }
  test_insert_node(&w, h1, {0, 0, 0}, {.MESH, .PAWN})
  test_insert_node(&w, h2, {1, 0, 0}, {.SPRITE, .ENEMY})
  test_insert_node(&w, h3, {2, 0, 0}, {.LIGHT})
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query for nodes with PAWN or ENEMY tag
  world.query_sphere(&w, {1, 0, 0}, 5.0, &results, tags_any = {.PAWN, .ENEMY})
  testing.expect(
    t,
    len(results) == 2,
    "Should find 2 nodes with PAWN or ENEMY tag",
  )
}

@(test)
test_aoe_tag_filtering_all :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  h2 := resources.Handle {
    index      = 2,
    generation = 0,
  }
  h3 := resources.Handle {
    index      = 3,
    generation = 0,
  }
  test_insert_node(&w, h1, {0, 0, 0}, {.MESH, .VISIBLE, .DYNAMIC})
  test_insert_node(&w, h2, {1, 0, 0}, {.MESH, .DYNAMIC}) // Missing VISIBLE
  test_insert_node(&w, h3, {2, 0, 0}, {.MESH, .VISIBLE, .STATIC}) // Missing DYNAMIC
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query for nodes that have ALL of: MESH, VISIBLE, DYNAMIC
  world.query_sphere(
    &w,
    {1, 0, 0},
    5.0,
    &results,
    tags_all = {.MESH, .VISIBLE, .DYNAMIC},
  )
  testing.expect(
    t,
    len(results) == 1,
    "Should find exactly 1 node with all required tags",
  )
  testing.expect(t, results[0].index == 1, "Should find node 1")
}

@(test)
test_aoe_tag_filtering_none :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  h2 := resources.Handle {
    index      = 2,
    generation = 0,
  }
  h3 := resources.Handle {
    index      = 3,
    generation = 0,
  }
  test_insert_node(&w, h1, {0, 0, 0}, {.MESH, .FRIENDLY})
  test_insert_node(&w, h2, {1, 0, 0}, {.SPRITE, .ENEMY})
  test_insert_node(&w, h3, {2, 0, 0}, {.LIGHT, .FRIENDLY})
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query for nodes that DON'T have ENEMY tag
  world.query_sphere(&w, {1, 0, 0}, 5.0, &results, tags_none = {.ENEMY})
  testing.expect(t, len(results) == 2, "Should find 2 nodes without ENEMY tag")
}

@(test)
test_aoe_tag_filtering_combined :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  h2 := resources.Handle {
    index      = 2,
    generation = 0,
  }
  h3 := resources.Handle {
    index      = 3,
    generation = 0,
  }
  h4 := resources.Handle {
    index      = 4,
    generation = 0,
  }
  test_insert_node(&w, h1, {0, 0, 0}, {.MESH, .PAWN, .FRIENDLY, .VISIBLE})
  test_insert_node(&w, h2, {1, 0, 0}, {.MESH, .PAWN, .ENEMY, .VISIBLE})
  test_insert_node(&w, h3, {2, 0, 0}, {.SPRITE, .ACTOR, .FRIENDLY})
  test_insert_node(&w, h4, {3, 0, 0}, {.MESH, .ACTOR, .ENEMY})
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Find visible pawns that are NOT enemies
  world.query_sphere(
    &w,
    {1, 0, 0},
    5.0,
    &results,
    tags_all = {.PAWN, .VISIBLE},
    tags_none = {.ENEMY},
  )
  testing.expect(
    t,
    len(results) == 1,
    "Should find exactly 1 node matching all criteria",
  )
  testing.expect(
    t,
    results[0].index == 1,
    "Should find the friendly visible pawn",
  )
}

// End-to-End Tests - Test with realistic World integration

@(test)
test_aoe_world_integration :: proc(t: ^testing.T) {
  w: world.World
  world.init(&w)
  defer world.destroy(&w, nil, nil)
  // Spawn some nodes
  h1, n1, ok1 := world.spawn_at(&w, {0, 0, 0}, world.MeshAttachment{})
  h2, n2, ok2 := world.spawn_at(&w, {5, 0, 0}, world.SpriteAttachment{})
  h3, n3, ok3 := world.spawn_at(&w, {10, 0, 0}, world.LightAttachment{})
  testing.expect(t, ok1 && ok2 && ok3, "All spawns should succeed")
  // Tag nodes manually for test
  n1.tags = {.MESH, .PAWN, .FRIENDLY}
  n2.tags = {.SPRITE, .ENEMY}
  n3.tags = {.LIGHT}
  // Traverse to build world matrices and mark pending updates
  world.traverse(&w)
  // Process pending updates to populate octree
  world.process_octree_updates(&w, nil)
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query for enemies within range
  world.query_sphere(&w, {5, 0, 0}, 8.0, &results, tags_any = {.ENEMY})
  testing.expect(t, len(results) >= 1, "Should find at least 1 enemy")
}

@(test)
test_aoe_edge_cases :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query empty octree
  world.query_sphere(&w, {0, 0, 0}, 5.0, &results)
  testing.expect(
    t,
    len(results) == 0,
    "Should find no results in empty octree",
  )
  // Query with empty tag filter (should return all)
  h1 := resources.Handle {
    index      = 1,
    generation = 0,
  }
  test_insert_node(&w, h1, {0, 0, 0}, {.MESH})
  clear(&results)
  world.query_sphere(&w, {0, 0, 0}, 5.0, &results)
  testing.expect(t, len(results) == 1, "Should find node with no tag filter")
  // Query with very small radius (note: items have 0.5 radius AABB, so might still find them)
  clear(&results)
  world.query_sphere(&w, {0, 0, 0}, 0.1, &results)
  // Due to AABB approximation (0.5 radius), we might still find the node
  testing.expect(
    t,
    len(results) <= 1,
    "Should find at most 1 result with very small radius",
  )
  // Query fan with zero angle
  clear(&results)
  world.query_fan(&w, {0, 0, 0}, {1, 0, 0}, 5.0, 0.0, &results)
  testing.expect(
    t,
    len(results) == 0,
    "Should find no results with zero angle",
  )
}

@(test)
test_aoe_incremental_updates :: proc(t: ^testing.T) {
  w: world.World
  world.init(&w)
  defer world.destroy(&w, nil, nil)
  // Spawn a node
  h1, n1, ok := world.spawn_at(&w, {0, 0, 0})
  testing.expect(t, ok, "Spawn should succeed")
  n1.tags = {.MESH, .PAWN}
  // Traverse to initialize world matrices and mark pending updates
  world.traverse(&w)
  // Process pending updates to populate octree
  world.process_octree_updates(&w, nil)
  results := make([dynamic]resources.Handle)
  defer delete(results)
  // Query at original position
  world.query_sphere(&w, {0, 0, 0}, 2.0, &results)
  testing.expect(t, len(results) == 1, "Should find node at original position")
  // Move the node
  world.translate(&w, h1, 10, 0, 0)
  // Traverse to update world matrices and mark for octree update
  world.traverse(&w)
  // Process octree updates (remove from old position, insert at new)
  world.process_octree_updates(&w, nil)
  // Query old position
  clear(&results)
  world.query_sphere(&w, {0, 0, 0}, 2.0, &results)
  testing.expect(
    t,
    len(results) == 0,
    "Should not find node at old position after move",
  )
  // Query new position
  clear(&results)
  world.query_sphere(&w, {10, 0, 0}, 2.0, &results)
  testing.expect(t, len(results) == 1, "Should find node at new position")
}

@(test)
test_aoe_multiple_query_shapes :: proc(t: ^testing.T) {
  w := make_test_world()
  defer world.destroy(&w, nil, nil)
  // Create a grid of nodes
  for x in -2 ..= 2 {
    for z in -2 ..= 2 {
      handle := resources.Handle {
        index      = u32(((x + 2) * 5 + (z + 2))),
        generation = 0,
      }
      pos := [3]f32{f32(x) * 3, 0, f32(z) * 3}
      test_insert_node(&w, handle, pos, {.MESH, .PAWN})
    }
  }
  results_sphere := make([dynamic]resources.Handle)
  results_cube := make([dynamic]resources.Handle)
  results_disc := make([dynamic]resources.Handle)
  results_fan := make([dynamic]resources.Handle)
  defer delete(results_sphere)
  defer delete(results_cube)
  defer delete(results_disc)
  defer delete(results_fan)
  // Test all query shapes at same location
  center := [3]f32{0, 0, 0}
  world.query_sphere(&w, center, 5.0, &results_sphere)
  world.query_cube(&w, center, {5, 5, 5}, &results_cube)
  world.query_disc(&w, center, {0, 1, 0}, 5.0, &results_disc)
  world.query_fan(&w, center, {1, 0, 0}, 5.0, math.PI, &results_fan)
  // All queries should find some nodes
  testing.expect(t, len(results_sphere) > 0, "Sphere query should find nodes")
  testing.expect(t, len(results_cube) > 0, "Cube query should find nodes")
  testing.expect(t, len(results_disc) > 0, "Disc query should find nodes")
  testing.expect(t, len(results_fan) > 0, "Fan query should find nodes")
  // Cube should typically find more than sphere (corners extend further)
  log.infof(
    "Sphere: %d, Cube: %d, Disc: %d, Fan: %d",
    len(results_sphere),
    len(results_cube),
    len(results_disc),
    len(results_fan),
  )
}
