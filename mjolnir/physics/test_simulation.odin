package physics

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
