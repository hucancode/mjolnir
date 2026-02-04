package physics

import "core:fmt"
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
  init(&physics_world, {0, -20, 0}, false) // 2x earth gravity
  defer destroy(&physics_world)
  create_static_body_box(
    &physics_world,
    {GROUND_HALF, 0.5, GROUND_HALF},
    {0, -0.5, 0},
    linalg.QUATERNIONF32_IDENTITY,
  )
  create_static_body_sphere(
    &physics_world,
    SPHERE_RADIUS,
    {2.5, SPHERE_RADIUS, 0},
    linalg.QUATERNIONF32_IDENTITY,
  )
  body_handles: [PIECE_COUNT]DynamicRigidBodyHandle
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

        switch idx % 3 {
        case 0:
          // Cylinder
          body_handles[idx] = create_dynamic_body_cylinder(
            &physics_world,
            1.0,
            2.0,
            pos,
            linalg.QUATERNIONF32_IDENTITY,
            50.0,
          )
          if body, ok := get_dynamic_body(&physics_world, body_handles[idx]);
             ok {
            set_cylinder_inertia(body, 1.0, 2.0)
          }
        case 1:
          // Cube
          body_handles[idx] = create_dynamic_body_box(
            &physics_world,
            {1.0, 1.0, 1.0},
            pos,
            linalg.QUATERNIONF32_IDENTITY,
            50.0,
          )
          if body, ok := get_dynamic_body(&physics_world, body_handles[idx]);
             ok {
            set_box_inertia(body, {1.0, 1.0, 1.0})
          }
        case 2:
          // Sphere
          body_handles[idx] = create_dynamic_body_sphere(
            &physics_world,
            1.0,
            pos,
            linalg.QUATERNIONF32_IDENTITY,
            50.0,
          )
          if body, ok := get_dynamic_body(&physics_world, body_handles[idx]);
             ok {
            set_sphere_inertia(body, 1.0)
          }
        }
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
    body, ok := get_dynamic_body(&physics_world, handle)
    if !ok do continue // already removed by KILL_Y cleanup
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
