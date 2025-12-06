package tests

import cont "../mjolnir/containers"
import "../mjolnir/geometry"
import "../mjolnir/physics"
import "../mjolnir/resources"
import "../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"

// Helper to spawn a test body at a position
spawn_test_body :: proc(
  phys: ^physics.World,
  position: [3]f32,
  is_static: bool = true,
) -> physics.RigidBodyHandle {
  body_handle := physics.create_body(phys, position, is_static = is_static)
  physics.create_collider_sphere(phys, body_handle, 0.5)
  return body_handle
}

@(test)
test_physics_query_sphere :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  // Spawn bodies at specific positions
  b1 := spawn_test_body(&phys, {0, 0, 0})
  b2 := spawn_test_body(&phys, {5, 0, 0})
  b3 := spawn_test_body(&phys, {10, 0, 0})
  physics.step(&phys, 0.0)
  // Query sphere at origin with radius 3
  results := make([dynamic]physics.RigidBodyHandle)
  defer delete(results)
  physics.query_sphere(&phys, {0, 0, 0}, 3.0, &results)
  testing.expect(
    t,
    len(results) == 1,
    "Should find exactly 1 body within radius 3",
  )
  testing.expect(t, results[0] == b1, "Should find body b1")
  // Query larger sphere
  clear(&results)
  physics.query_sphere(&phys, {0, 0, 0}, 8.0, &results)
  testing.expect(
    t,
    len(results) >= 2,
    "Should find at least 2 bodies within radius 8",
  )
}

@(test)
test_physics_query_box :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  b1 := spawn_test_body(&phys, {0, 0, 0})
  b2 := spawn_test_body(&phys, {2, 2, 2})
  b3 := spawn_test_body(&phys, {-2, -2, -2})
  b4 := spawn_test_body(&phys, {10, 10, 10})
  physics.step(&phys, 0.0)
  results := make([dynamic]physics.RigidBodyHandle)
  defer delete(results)
  // Query box centered at origin with half-extent 3
  bounds := geometry.Aabb {
    min = {-3, -3, -3},
    max = {3, 3, 3},
  }
  physics.query_box(&phys, bounds, &results)
  testing.expect(t, len(results) == 3, "Should find exactly 3 bodies in box")
}

@(test)
test_physics_raycast_basic :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  b1 := spawn_test_body(&phys, {5, 0, 0})
  physics.step(&phys, 0.0)
  // Raycast along X axis
  ray := geometry.Ray {
    origin    = {0, 0, 0},
    direction = {1, 0, 0},
  }
  hit := physics.raycast(&phys, ray, 100.0)
  testing.expect(t, hit.hit, "Should hit the body")
  testing.expect(t, hit.body_handle == b1, "Should hit body b1")
  testing.expect(
    t,
    hit.t > 4.0 && hit.t < 6.0,
    "Hit distance should be around 5",
  )
}

@(test)
test_physics_raycast_miss :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  spawn_test_body(&phys, {5, 0, 0})
  physics.step(&phys, 0.0)
  // Raycast in opposite direction
  ray := geometry.Ray {
    origin    = {0, 0, 0},
    direction = {-1, 0, 0},
  }
  hit := physics.raycast(&phys, ray, 100.0)
  testing.expect(t, !hit.hit, "Should not hit anything")
}

@(test)
test_physics_raycast_single :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  // Spawn multiple bodies in a line
  b1 := spawn_test_body(&phys, {3, 0, 0})
  b2 := spawn_test_body(&phys, {6, 0, 0})
  b3 := spawn_test_body(&phys, {9, 0, 0})
  physics.step(&phys, 0.0)
  // Raycast - should hit first body (early exit)
  ray := geometry.Ray {
    origin    = {0, 0, 0},
    direction = {1, 0, 0},
  }
  hit := physics.raycast_single(&phys, ray, 100.0)
  testing.expect(t, hit.hit, "Should hit a body")
  // Should hit closest body
  testing.expect(t, hit.t < 4.0, "Should hit closest body")
}

// Integration Tests - Test point-in-collider functions

@(test)
test_point_cylinder :: proc(t: ^testing.T) {
  cylinder := physics.CylinderCollider {
    radius   = 2.0,
    height   = 4.0,
  }
  center := [3]f32{0, 0, 0}
  // Point inside cylinder
  testing.expect(
    t,
    physics.test_point_cylinder({0, 0, 0}, center, linalg.QUATERNIONF32_IDENTITY, cylinder),
    "Point at center should be inside",
  )
  testing.expect(
    t,
    physics.test_point_cylinder({1, 1, 0}, center, linalg.QUATERNIONF32_IDENTITY, cylinder),
    "Point within radius and height should be inside",
  )
  // Point outside cylinder (beyond radius)
  testing.expect(
    t,
    !physics.test_point_cylinder({3, 0, 0}, center, linalg.QUATERNIONF32_IDENTITY, cylinder),
    "Point beyond radius should be outside",
  )
  // Point outside cylinder (beyond height)
  testing.expect(
    t,
    !physics.test_point_cylinder({0, 3, 0}, center, linalg.QUATERNIONF32_IDENTITY, cylinder),
    "Point beyond height should be outside",
  )
}

@(test)
test_point_fan :: proc(t: ^testing.T) {
  fan := physics.FanCollider {
    radius   = 5.0,
    height   = 2.0,
    angle    = math.PI / 2, // 90 degrees
  }
  center := [3]f32{0, 0, 0}
  // Point inside fan (forward direction +Z)
  testing.expect(
    t,
    physics.test_point_fan({0, 0, 3}, center, linalg.QUATERNIONF32_IDENTITY, fan),
    "Point in forward direction should be inside",
  )
  // Point inside fan (45 degrees from forward)
  testing.expect(
    t,
    physics.test_point_fan({2, 0, 2}, center, linalg.QUATERNIONF32_IDENTITY, fan),
    "Point at 45 degrees should be inside 90-degree fan",
  )
  // Point outside fan (beyond angle)
  testing.expect(
    t,
    !physics.test_point_fan({3, 0, 0}, center, linalg.QUATERNIONF32_IDENTITY, fan),
    "Point at 90 degrees (perpendicular) should be outside",
  )
  // Point outside fan (opposite direction)
  testing.expect(
    t,
    !physics.test_point_fan({0, 0, -3}, center, linalg.QUATERNIONF32_IDENTITY, fan),
    "Point in opposite direction should be outside",
  )
  // Point outside fan (beyond radius)
  testing.expect(
    t,
    !physics.test_point_fan({0, 0, 6}, center, linalg.QUATERNIONF32_IDENTITY, fan),
    "Point beyond radius should be outside",
  )
  // Point outside fan (beyond height)
  testing.expect(
    t,
    !physics.test_point_fan({0, 3, 3}, center, linalg.QUATERNIONF32_IDENTITY, fan),
    "Point beyond height should be outside",
  )
}

// End-to-End Tests - Test with realistic integration

@(test)
test_physics_world_integration :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  b1 := spawn_test_body(&phys, {0, 0, 0})
  b2 := spawn_test_body(&phys, {5, 0, 0})
  b3 := spawn_test_body(&phys, {10, 0, 0})
  physics.step(&phys, 0.0)
  testing.expect(
    t,
    b1.generation > 0 && b2.generation > 0 && b3.generation > 0,
    "All bodies should be created",
  )
  // Query for bodies within range
  results := make([dynamic]physics.RigidBodyHandle)
  defer delete(results)
  physics.query_sphere(&phys, {5, 0, 0}, 8.0, &results)
  testing.expect(t, len(results) >= 2, "Should find at least 2 bodies")
}

@(test)
test_physics_edge_cases :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  results := make([dynamic]physics.RigidBodyHandle)
  defer delete(results)
  physics.query_sphere(&phys, {0, 0, 0}, 5.0, &results)
  testing.expect(
    t,
    len(results) == 0,
    "Should find no results in empty physics world",
  )
  // Spawn one body and query
  b1 := spawn_test_body(&phys, {0, 0, 0})
  physics.step(&phys, 0.0)
  clear(&results)
  physics.query_sphere(&phys, {0, 0, 0}, 5.0, &results)
  testing.expect(t, len(results) == 1, "Should find one body")
  // Query with very small radius
  clear(&results)
  physics.query_sphere(&phys, {0, 0, 0}, 0.1, &results)
  testing.expect(
    t,
    len(results) <= 1,
    "Should find at most 1 result with very small radius",
  )
  // Raycast with max_dist = 0
  ray := geometry.Ray {
    origin    = {0, 0, 0},
    direction = {1, 0, 0},
  }
  hit := physics.raycast(&phys, ray, 0.0)
  testing.expect(t, !hit.hit, "Should not hit with zero max distance")
}

@(test)
test_physics_cylinder_collision :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  body_handle := physics.create_body(&phys, is_static = true)
  physics.create_collider_cylinder(&phys, body_handle, 2.0, 4.0)
  physics.step(&phys, 0.0)
  // Query for bodies - should find the cylinder
  results := make([dynamic]physics.RigidBodyHandle)
  defer delete(results)
  physics.query_sphere(&phys, {0, 0, 0}, 5.0, &results)
  testing.expect(t, len(results) == 1, "Should find cylinder body")
  testing.expect(t, results[0] == body_handle, "Should find the cylinder body")
}

@(test)
test_physics_fan_trigger :: proc(t: ^testing.T) {
  phys: physics.World
  physics.init(&phys, enable_parallel = false)
  defer physics.destroy(&phys)
  // Test point-in-fan directly
  fan := physics.FanCollider {
    radius   = 5.0,
    height   = 2.0,
    angle    = math.PI * 0.5,
  }
  testing.expect(
    t,
    physics.test_point_fan({0, 0, 3}, {0, 0, 0}, linalg.QUATERNIONF32_IDENTITY, fan),
    "Point should be inside fan",
  )
  testing.expect(
    t,
    !physics.test_point_fan({3, 0, 0}, {0, 0, 0}, linalg.QUATERNIONF32_IDENTITY, fan),
    "Point should be outside fan",
  )
}
