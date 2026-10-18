#+build !js
#+private
package physics

import "../containers"
import "../geometry"
import "core:math/linalg"
import "core:testing"

// Helper to spawn a dynamic test body at a position
spawn_test_body :: proc(phys: ^World, position: [3]f32) -> BodyHandle {
  return body_create(phys, position, collider = SphereCollider{radius = 0.5}, mass = 1.0)
}

@(private = "file")
overlap_sphere :: proc(phys: ^World, center: [3]f32, radius: f32, results: ^[dynamic]BodyHandle) {
  overlap(phys, SphereCollider{radius = radius}, center, linalg.QUATERNIONF32_IDENTITY, results)
}

@(test)
test_physics_overlap_sphere :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  b1 := spawn_test_body(&phys, {0, 0, 0})
  spawn_test_body(&phys, {5, 0, 0})
  spawn_test_body(&phys, {10, 0, 0})
  step(&phys, 0.0)
  results := make([dynamic]BodyHandle)
  defer delete(results)
  overlap_sphere(&phys, {0, 0, 0}, 3.0, &results)
  testing.expect(t, len(results) == 1, "Should find exactly 1 body within radius 3")
  testing.expect(t, results[0] == b1, "Should find body b1")
  overlap_sphere(&phys, {0, 0, 0}, 8.0, &results)
  testing.expect(t, len(results) == 2, "Should find 2 bodies within radius 8")
}

@(test)
test_physics_overlap_box :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  spawn_test_body(&phys, {0, 0, 0})
  spawn_test_body(&phys, {2, 2, 2})
  spawn_test_body(&phys, {-2, -2, -2})
  spawn_test_body(&phys, {10, 10, 10})
  results := make([dynamic]BodyHandle)
  defer delete(results)
  overlap(&phys, BoxCollider{half_extents = {3, 3, 3}}, {}, linalg.QUATERNIONF32_IDENTITY, &results)
  testing.expect(t, len(results) == 3, "Should find exactly 3 bodies in box")
}

@(test)
test_physics_overlap_includes_static :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  s := body_create(&phys, {0, 0, 0}, collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}})
  results := make([dynamic]BodyHandle)
  defer delete(results)
  // No step: queries rebuild the dirty broadphase themselves
  overlap_sphere(&phys, {1, 0, 0}, 0.6, &results)
  testing.expect(t, len(results) == 1 && results[0] == s, "Should find the static box")
  overlap_sphere(&phys, {1.5, 0, 0}, 0.6, &results)
  testing.expect(t, len(results) == 0, "Sphere clear of the box should find nothing")
}

@(test)
test_physics_raycast_basic :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  b1 := spawn_test_body(&phys, {5, 0, 0})
  step(&phys, 0.0)
  hit := raycast(&phys, geometry.Ray{origin = {0, 0, 0}, direction = {1, 0, 0}}, 100.0)
  testing.expect(t, hit.hit, "Should hit the body")
  testing.expect(t, hit.body == b1, "Should hit body b1")
  testing.expect(t, hit.t > 4.0 && hit.t < 6.0, "Hit distance should be around 5")
}

@(test)
test_physics_raycast_miss :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  spawn_test_body(&phys, {5, 0, 0})
  step(&phys, 0.0)
  hit := raycast(&phys, geometry.Ray{origin = {0, 0, 0}, direction = {-1, 0, 0}}, 100.0)
  testing.expect(t, !hit.hit, "Should not hit anything")
}

@(test)
test_physics_raycast_first_hit :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  spawn_test_body(&phys, {3, 0, 0})
  spawn_test_body(&phys, {6, 0, 0})
  spawn_test_body(&phys, {9, 0, 0})
  step(&phys, 0.0)
  hit := raycast(&phys, geometry.Ray{origin = {0, 0, 0}, direction = {1, 0, 0}}, 100.0, first_hit = true)
  testing.expect(t, hit.hit, "Should hit a body")
}

@(test)
test_physics_edge_cases :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  results := make([dynamic]BodyHandle)
  defer delete(results)
  overlap_sphere(&phys, {0, 0, 0}, 5.0, &results)
  testing.expect(t, len(results) == 0, "Should find no results in empty physics world")
  spawn_test_body(&phys, {0, 0, 0})
  step(&phys, 0.0)
  overlap_sphere(&phys, {0, 0, 0}, 5.0, &results)
  testing.expect(t, len(results) == 1, "Should find one body")
  overlap_sphere(&phys, {0, 0, 0}, 0.1, &results)
  testing.expect(t, len(results) == 1, "Small sphere inside the body overlaps it")
  hit := raycast(&phys, geometry.Ray{origin = {0, 0, 0}, direction = {1, 0, 0}}, 0.0)
  testing.expect(t, !hit.hit, "Should not hit with zero max distance")
}

@(test)
test_physics_cylinder_overlap :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  body_handle := body_create(&phys, {}, collider = CylinderCollider{radius = 2.0, half_height = 2.0}, mass = 1.0)
  step(&phys, 0.0)
  results := make([dynamic]BodyHandle)
  defer delete(results)
  overlap_sphere(&phys, {0, 0, 0}, 5.0, &results)
  testing.expect(t, len(results) == 1, "Should find cylinder body")
  testing.expect(t, results[0] == body_handle, "Should find the cylinder body")
  // Sphere touching the curved wall without containing the center
  overlap_sphere(&phys, {2.5, 0, 0}, 1.0, &results)
  testing.expect(t, len(results) == 1, "Sphere grazing the wall should overlap")
}

@(test)
test_physics_sensor_overlap :: proc(t: ^testing.T) {
  phys: World
  init(&phys, gravity = {}, thread_count = 1)
  defer shutdown(&phys)
  sensor := body_create(&phys, {0, 0, 0}, collider = BoxCollider{half_extents = {1, 1, 1}}, is_sensor = true)
  inside := spawn_test_body(&phys, {0.5, 0, 0})
  spawn_test_body(&phys, {5, 0, 0})
  step(&phys, 1.0 / 60.0)
  testing.expectf(t, len(phys.sensor_overlaps) == 1, "overlaps = %v", phys.sensor_overlaps)
  if len(phys.sensor_overlaps) == 1 {
    testing.expect(t, phys.sensor_overlaps[0] == SensorOverlap{sensor, inside})
  }
  // Sensors are invisible to queries
  testing.expect(t, raycast(&phys, geometry.Ray{origin = {0, 5, 0.8}, direction = {0, -1, 0}}).hit == false)
}

@(test)
test_physics_kill_y :: proc(t: ^testing.T) {
  phys: World
  init(&phys, thread_count = 1)
  defer shutdown(&phys)
  user := containers.Handle{index = 7, generation = 1}
  falling := body_create(&phys, {0, KILL_Y + 1, 0}, collider = SphereCollider{radius = 0.5}, mass = 1.0, user = user)
  floor := body_create(&phys, {0, KILL_Y - 10, 0}, collider = BoxCollider{half_extents = {1, 1, 1}})
  kills := 0
  for _ in 0 ..< 120 {
    step(&phys, 1.0 / 60.0)
    for k in phys.killed {
      testing.expect(t, k == KilledBody{falling, user})
      kills += 1
    }
  }
  testing.expectf(t, kills == 1, "kills = %d", kills)
  _, alive := lookup(&phys, falling)
  testing.expect(t, !alive, "Fallen body should be destroyed")
  _, floor_alive := lookup(&phys, floor)
  testing.expect(t, floor_alive, "Static bodies below KILL_Y stay")
}
