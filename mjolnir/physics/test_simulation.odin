#+build !js
package physics

import "core:math/linalg"
import "core:testing"

@(test)
test_cubes_should_not_sink :: proc(t: ^testing.T) {
  NX :: 3
  NY :: 1
  NZ :: 3
  PIECE_COUNT :: NX * NY * NZ
  SPHERE_RADIUS :: 3.0
  GROUND_HALF :: f32(14.0)
  physics_world: World
  init(&physics_world, {0, -20, 0}, thread_count = 1) // 2x earth gravity
  defer shutdown(&physics_world)
  create_body(&physics_world, {0, -0.5, 0}, collider = BoxCollider{half_extents = {GROUND_HALF, 0.5, GROUND_HALF}})
  create_body(&physics_world, {2.5, SPHERE_RADIUS, 0}, collider = SphereCollider{radius = SPHERE_RADIUS})
  body_handles: [PIECE_COUNT]BodyHandle
  idx := 0
  for x in 0 ..< NX {
    for y in 0 ..< NY {
      for z in 0 ..< NZ {
        if idx >= PIECE_COUNT do break
        pos := [3]f32 {
          f32(x - NX / 2) * 3.0,
          f32(y) * 3.0 + 10.0,
          f32(z - NZ / 2) * 3.0,
        }

        colliders := [3]Collider {
          CylinderCollider{radius = 1.0, height = 2.0},
          BoxCollider{half_extents = {1.0, 1.0, 1.0}},
          SphereCollider{radius = 1.0},
        }
        body_handles[idx] = create_body(&physics_world, pos, collider = colliders[idx % 3], mass = 50.0)
        idx += 1
      }
    }
  }
  // Simulate 1000 steps at 60 FPS (dt = 1/60)
  dt :: 1.0 / 60.0
  for i in 0 ..< 1000 {
    step(&physics_world, dt)
  }
  // Verify no body sinks through ground where ground exists.
  // Bodies that rolled beyond ground edges are expected to fall — same as
  // edge bodies in the example (ground is 14x14, bodies start at up to ±48).
  on_ground := 0
  for handle, i in body_handles {
    // Fell off the ground edge and was killed below KILL_Y
    body := get_body(&physics_world, handle) or_continue
    // Outside ground bounds — no ground underneath, expected to fall
    if body.position.x < -GROUND_HALF ||
       body.position.x > GROUND_HALF ||
       body.position.z < -GROUND_HALF ||
       body.position.z > GROUND_HALF {
      continue
    }
    on_ground += 1
    testing.expectf(
      t,
      body.position.y >= 0.0,
      "Body %d sank through ground at pos=%v",
      i,
      body.position,
    )
  }
  testing.expectf(
    t,
    on_ground > 0,
    "No bodies remained on ground — all fell off edges",
  )
}

@(test)
test_resting_body_falls_asleep :: proc(t: ^testing.T) {
  physics_world: World
  init(&physics_world, thread_count = 1)
  defer shutdown(&physics_world)
  create_body(&physics_world, {0, -0.5, 0}, collider = BoxCollider{half_extents = {10, 0.5, 10}})
  handle := create_body(&physics_world, {0, 0.5, 0}, collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 1)
  for _ in 0 ..< 120 {
    step(&physics_world, 1.0 / 60.0)
  }
  body := get_body(&physics_world, handle)
  testing.expect(t, body.is_sleeping, "box resting on the ground should be asleep after 2s")
}

// An 8x8x8 block of boxes dropped on the ground runs the multi-threaded
// graph-colored solver (hundreds of contacts) and must settle, not keep
// churning.
@(test)
test_parallel_pile_settles :: proc(t: ^testing.T) {
  N :: 8
  physics_world: World
  init(&physics_world, thread_count = 4)
  defer shutdown(&physics_world)
  create_body(&physics_world, {0, -0.5, 0}, collider = BoxCollider{half_extents = {30, 0.5, 30}})
  handles: [N * N * N]BodyHandle
  i := 0
  for x in 0 ..< N {
    for y in 0 ..< N {
      for z in 0 ..< N {
        pos := [3]f32{f32(x) * 1.1, f32(y) * 1.1 + 2, f32(z) * 1.1}
        handles[i] = create_body(&physics_world, pos, collider = BoxCollider{half_extents = {0.5, 0.5, 0.5}}, mass = 1)
        i += 1
      }
    }
  }
  max_contacts := 0
  for _ in 0 ..< 600 {
    step(&physics_world, 1.0 / 60.0)
    max_contacts = max(max_contacts, physics_world.last_perf.contact_count)
  }
  testing.expect(t, max_contacts >= SOLVER_PARALLEL_THRESHOLD)
  max_speed: f32
  for handle in handles {
    body := get_body(&physics_world, handle) or_continue
    max_speed = max(max_speed, linalg.length(body.velocity))
  }
  testing.expectf(t, max_speed < 2.0, "pile still churning: max speed %v m/s", max_speed)
}
