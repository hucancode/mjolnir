package tests

import "../mjolnir/geometry"
import "../mjolnir/resources"
import "../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"

// Unit Tests - Test with hard-coded perfect inputs

@(test)
test_aoe_insert_and_query_sphere :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-20, -20, -20}, max = {20, 20, 20}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  // Insert nodes at specific positions
  h1 := resources.Handle{index = 1, generation = 0}
  h2 := resources.Handle{index = 2, generation = 0}
  h3 := resources.Handle{index = 3, generation = 0}

  world.aoe_insert(&aoe, h1, {0, 0, 0}, {.MESH})
  world.aoe_insert(&aoe, h2, {5, 0, 0}, {.SPRITE})
  world.aoe_insert(&aoe, h3, {10, 0, 0}, {.LIGHT})

  // Query sphere at origin with radius 3
  results := make([dynamic]resources.Handle)
  defer delete(results)

  world.aoe_query_sphere(&aoe, {0, 0, 0}, 3.0, &results)
  testing.expect(t, len(results) == 1, "Should find exactly 1 node within radius 3")
  testing.expect(t, results[0].index == 1, "Should find node with index 1")

  // Query larger sphere
  clear(&results)
  world.aoe_query_sphere(&aoe, {0, 0, 0}, 8.0, &results)
  testing.expect(t, len(results) >= 2, "Should find at least 2 nodes within radius 8")
}

@(test)
test_aoe_query_cube :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-20, -20, -20}, max = {20, 20, 20}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  h1 := resources.Handle{index = 1, generation = 0}
  h2 := resources.Handle{index = 2, generation = 0}
  h3 := resources.Handle{index = 3, generation = 0}
  h4 := resources.Handle{index = 4, generation = 0}

  world.aoe_insert(&aoe, h1, {0, 0, 0}, {.MESH})
  world.aoe_insert(&aoe, h2, {2, 2, 2}, {.MESH})
  world.aoe_insert(&aoe, h3, {-2, -2, -2}, {.SPRITE})
  world.aoe_insert(&aoe, h4, {10, 10, 10}, {.LIGHT})

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Query cube centered at origin with half-extent 3
  world.aoe_query_cube(&aoe, {0, 0, 0}, {3, 3, 3}, &results)
  testing.expect(t, len(results) == 3, "Should find exactly 3 nodes in cube")
}

@(test)
test_aoe_query_disc :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-20, -20, -20}, max = {20, 20, 20}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  h1 := resources.Handle{index = 1, generation = 0}
  h2 := resources.Handle{index = 2, generation = 0}
  h3 := resources.Handle{index = 3, generation = 0}
  h4 := resources.Handle{index = 4, generation = 0}

  // Insert nodes on XZ plane
  world.aoe_insert(&aoe, h1, {0, 0, 0}, {.MESH})
  world.aoe_insert(&aoe, h2, {2, 0, 0}, {.MESH})
  world.aoe_insert(&aoe, h3, {0, 5, 0}, {.SPRITE}) // Above plane
  world.aoe_insert(&aoe, h4, {0, 0, 2}, {.LIGHT})

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Query disc on XZ plane (Y-up normal) with radius 3
  world.aoe_query_disc(&aoe, {0, 0, 0}, {0, 1, 0}, 3.0, &results)
  testing.expect(t, len(results) == 3, "Should find 3 nodes on disc (excluding node above plane)")
}

@(test)
test_aoe_query_fan :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-20, -20, -20}, max = {20, 20, 20}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  h1 := resources.Handle{index = 1, generation = 0}
  h2 := resources.Handle{index = 2, generation = 0}
  h3 := resources.Handle{index = 3, generation = 0}
  h4 := resources.Handle{index = 4, generation = 0}

  // Insert nodes in different directions from origin
  world.aoe_insert(&aoe, h1, {5, 0, 0}, {.MESH})   // Positive X
  world.aoe_insert(&aoe, h2, {-5, 0, 0}, {.MESH})  // Negative X
  world.aoe_insert(&aoe, h3, {0, 5, 0}, {.SPRITE}) // Positive Y
  world.aoe_insert(&aoe, h4, {3.5, 3.5, 0}, {.LIGHT}) // 45 degrees in XY

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Query 90-degree fan pointing in positive X direction
  world.aoe_query_fan(&aoe, {0, 0, 0}, {1, 0, 0}, 8.0, math.PI / 2, &results)
  testing.expect(t, len(results) >= 1, "Should find at least node in positive X direction")

  // Verify it doesn't include node in negative X
  found_negative_x := false
  for handle in results {
    if handle.index == 2 do found_negative_x = true
  }
  testing.expect(t, !found_negative_x, "Should not find node in opposite direction")
}

// Integration Tests - Test tag filtering

@(test)
test_aoe_tag_filtering_any :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-20, -20, -20}, max = {20, 20, 20}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  h1 := resources.Handle{index = 1, generation = 0}
  h2 := resources.Handle{index = 2, generation = 0}
  h3 := resources.Handle{index = 3, generation = 0}

  world.aoe_insert(&aoe, h1, {0, 0, 0}, {.MESH, .PAWN})
  world.aoe_insert(&aoe, h2, {1, 0, 0}, {.SPRITE, .ENEMY})
  world.aoe_insert(&aoe, h3, {2, 0, 0}, {.LIGHT})

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Query for nodes with PAWN or ENEMY tag
  world.aoe_query_sphere(&aoe, {1, 0, 0}, 5.0, &results, tags_any = {.PAWN, .ENEMY})
  testing.expect(t, len(results) == 2, "Should find 2 nodes with PAWN or ENEMY tag")
}

@(test)
test_aoe_tag_filtering_all :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-20, -20, -20}, max = {20, 20, 20}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  h1 := resources.Handle{index = 1, generation = 0}
  h2 := resources.Handle{index = 2, generation = 0}
  h3 := resources.Handle{index = 3, generation = 0}

  world.aoe_insert(&aoe, h1, {0, 0, 0}, {.MESH, .VISIBLE, .DYNAMIC})
  world.aoe_insert(&aoe, h2, {1, 0, 0}, {.MESH, .DYNAMIC}) // Missing VISIBLE
  world.aoe_insert(&aoe, h3, {2, 0, 0}, {.MESH, .VISIBLE, .STATIC}) // Missing DYNAMIC

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Query for nodes that have ALL of: MESH, VISIBLE, DYNAMIC
  world.aoe_query_sphere(&aoe, {1, 0, 0}, 5.0, &results, tags_all = {.MESH, .VISIBLE, .DYNAMIC})
  testing.expect(t, len(results) == 1, "Should find exactly 1 node with all required tags")
  testing.expect(t, results[0].index == 1, "Should find node 1")
}

@(test)
test_aoe_tag_filtering_none :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-20, -20, -20}, max = {20, 20, 20}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  h1 := resources.Handle{index = 1, generation = 0}
  h2 := resources.Handle{index = 2, generation = 0}
  h3 := resources.Handle{index = 3, generation = 0}

  world.aoe_insert(&aoe, h1, {0, 0, 0}, {.MESH, .FRIENDLY})
  world.aoe_insert(&aoe, h2, {1, 0, 0}, {.SPRITE, .ENEMY})
  world.aoe_insert(&aoe, h3, {2, 0, 0}, {.LIGHT, .FRIENDLY})

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Query for nodes that DON'T have ENEMY tag
  world.aoe_query_sphere(&aoe, {1, 0, 0}, 5.0, &results, tags_none = {.ENEMY})
  testing.expect(t, len(results) == 2, "Should find 2 nodes without ENEMY tag")
}

@(test)
test_aoe_tag_filtering_combined :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-30, -30, -30}, max = {30, 30, 30}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  h1 := resources.Handle{index = 1, generation = 0}
  h2 := resources.Handle{index = 2, generation = 0}
  h3 := resources.Handle{index = 3, generation = 0}
  h4 := resources.Handle{index = 4, generation = 0}

  world.aoe_insert(&aoe, h1, {0, 0, 0}, {.MESH, .PAWN, .FRIENDLY, .VISIBLE})
  world.aoe_insert(&aoe, h2, {1, 0, 0}, {.MESH, .PAWN, .ENEMY, .VISIBLE})
  world.aoe_insert(&aoe, h3, {2, 0, 0}, {.SPRITE, .ACTOR, .FRIENDLY})
  world.aoe_insert(&aoe, h4, {3, 0, 0}, {.MESH, .ACTOR, .ENEMY})

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Find visible pawns that are NOT enemies
  world.aoe_query_sphere(&aoe, {1, 0, 0}, 5.0, &results,
    tags_all = {.PAWN, .VISIBLE},
    tags_none = {.ENEMY})
  testing.expect(t, len(results) == 1, "Should find exactly 1 node matching all criteria")
  testing.expect(t, results[0].index == 1, "Should find the friendly visible pawn")
}

// End-to-End Tests - Test with realistic World integration

@(test)
test_aoe_world_integration :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  w: world.World
  world.init(&w)
  defer {
    world.destroy(&w, nil, nil)
  }

  // Spawn some nodes
  h1, n1, ok1 := world.spawn_at(&w, {0, 0, 0}, world.MeshAttachment{})
  h2, n2, ok2 := world.spawn_at(&w, {5, 0, 0}, world.SpriteAttachment{})
  h3, n3, ok3 := world.spawn_at(&w, {10, 0, 0}, world.LightAttachment{})

  testing.expect(t, ok1 && ok2 && ok3, "All spawns should succeed")

  // Tag nodes manually for test
  n1.tags = {.MESH, .PAWN, .FRIENDLY}
  n2.tags = {.SPRITE, .ENEMY}
  n3.tags = {.LIGHT}

  // Rebuild AOE octree from world
  world.aoe_rebuild_from_world(&w.aoe, &w)

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Query for enemies within range
  world.aoe_query_sphere(&w.aoe, {5, 0, 0}, 8.0, &results, tags_any = {.ENEMY})
  testing.expect(t, len(results) >= 1, "Should find at least 1 enemy")
}

@(test)
test_aoe_edge_cases :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-10, -10, -10}, max = {10, 10, 10}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  results := make([dynamic]resources.Handle)
  defer delete(results)

  // Query empty octree
  world.aoe_query_sphere(&aoe, {0, 0, 0}, 5.0, &results)
  testing.expect(t, len(results) == 0, "Should find no results in empty octree")

  // Query with empty tag filter (should return all)
  h1 := resources.Handle{index = 1, generation = 0}
  world.aoe_insert(&aoe, h1, {0, 0, 0}, {.MESH})
  clear(&results)
  world.aoe_query_sphere(&aoe, {0, 0, 0}, 5.0, &results)
  testing.expect(t, len(results) == 1, "Should find node with no tag filter")

  // Query with very small radius (note: items have 0.5 radius AABB, so might still find them)
  clear(&results)
  world.aoe_query_sphere(&aoe, {0, 0, 0}, 0.1, &results)
  // Due to AABB approximation (0.5 radius), we might still find the node
  testing.expect(t, len(results) <= 1, "Should find at most 1 result with very small radius")

  // Query fan with zero angle
  clear(&results)
  world.aoe_query_fan(&aoe, {0, 0, 0}, {1, 0, 0}, 5.0, 0.0, &results)
  testing.expect(t, len(results) == 0, "Should find no results with zero angle")
}

@(test)
test_aoe_remove_and_reinsert :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-20, -20, -20}, max = {20, 20, 20}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  h1 := resources.Handle{index = 1, generation = 0}
  old_pos := [3]f32{0, 0, 0}
  new_pos := [3]f32{10, 0, 0}
  tags := world.NodeTagSet{.MESH}

  world.aoe_insert(&aoe, h1, old_pos, tags)

  // Query old position
  results := make([dynamic]resources.Handle)
  defer delete(results)
  world.aoe_query_sphere(&aoe, old_pos, 2.0, &results)
  testing.expect(t, len(results) == 1, "Should find node at old position")

  // Remove and reinsert at new position (simpler than update)
  removed := world.aoe_remove(&aoe, h1, old_pos, tags)
  testing.expect(t, removed, "Remove should succeed")

  inserted := world.aoe_insert(&aoe, h1, new_pos, tags)
  testing.expect(t, inserted, "Reinsert should succeed")

  // Query old position again
  clear(&results)
  world.aoe_query_sphere(&aoe, old_pos, 2.0, &results)
  testing.expect(t, len(results) == 0, "Should not find node at old position after move")

  // Query new position
  clear(&results)
  world.aoe_query_sphere(&aoe, new_pos, 2.0, &results)
  testing.expect(t, len(results) == 1, "Should find node at new position")
}

@(test)
test_aoe_multiple_query_shapes :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)
  bounds := geometry.Aabb{min = {-30, -30, -30}, max = {30, 30, 30}}

  aoe: world.AOEOctree
  world.aoe_init(&aoe, bounds)
  defer world.aoe_destroy(&aoe)

  // Create a grid of nodes
  for x in -2 ..= 2 {
    for z in -2 ..= 2 {
      handle := resources.Handle{index = u32(((x + 2) * 5 + (z + 2))), generation = 0}
      pos := [3]f32{f32(x) * 3, 0, f32(z) * 3}
      world.aoe_insert(&aoe, handle, pos, {.MESH, .PAWN})
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

  world.aoe_query_sphere(&aoe, center, 5.0, &results_sphere)
  world.aoe_query_cube(&aoe, center, {5, 5, 5}, &results_cube)
  world.aoe_query_disc(&aoe, center, {0, 1, 0}, 5.0, &results_disc)
  world.aoe_query_fan(&aoe, center, {1, 0, 0}, 5.0, math.PI, &results_fan)

  // All queries should find some nodes
  testing.expect(t, len(results_sphere) > 0, "Sphere query should find nodes")
  testing.expect(t, len(results_cube) > 0, "Cube query should find nodes")
  testing.expect(t, len(results_disc) > 0, "Disc query should find nodes")
  testing.expect(t, len(results_fan) > 0, "Fan query should find nodes")

  // Cube should typically find more than sphere (corners extend further)
  log.infof("Sphere: %d, Cube: %d, Disc: %d, Fan: %d",
    len(results_sphere), len(results_cube), len(results_disc), len(results_fan))
}
