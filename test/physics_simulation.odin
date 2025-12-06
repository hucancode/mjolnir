package tests

import "../mjolnir/physics"
import "core:fmt"
import "core:math/linalg"
import "core:testing"

NX :: 3
NY :: 1
NZ :: 3
CUBE_COUNT :: NX * NY * NZ
SPHERE_RADIUS :: 3.0

@(test)
test_cubes_should_not_sink :: proc(t: ^testing.T) {
  physics_world: physics.World
  physics.init(&physics_world, {0, -20, 0}, false) // 2x earth gravity
  physics_world.enable_air_resistance = true
  defer physics.destroy(&physics_world)

  // Create ground
  ground_handle := physics.create_body_box(
    &physics_world,
    half_extents = {10.0, 0.5, 10.0},
    position = {0, -0.5, 0},
    rotation = linalg.QUATERNIONF32_IDENTITY,
    is_static = true,
  )

  // Create sphere
  sphere_handle := physics.create_body_sphere(
    &physics_world,
    radius = SPHERE_RADIUS,
    position = {0, SPHERE_RADIUS, 0},
    rotation = linalg.QUATERNIONF32_IDENTITY,
    is_static = true,
  )
  if body, ok := physics.get_body(&physics_world, sphere_handle); ok {
    physics.set_sphere_inertia(body, SPHERE_RADIUS)
  }

  // Create cube grid (3x1x3 = 9 cubes)
  cube_handles: [CUBE_COUNT]physics.RigidBodyHandle
  idx := 0
  for x in 0 ..< NX {
    for y in 0 ..< NY {
      for z in 0 ..< NZ {
        if idx >= CUBE_COUNT do break
        pos := [3]f32{
          f32(x - NX / 2) * 3.0,
          f32(y) * 3.0 + 10.0, // Start at height 10
          f32(z - NZ / 2) * 3.0,
        }
        cube_handles[idx] = physics.create_body_box(
          &physics_world,
          half_extents = {1.0, 1.0, 1.0},
          position = pos,
          rotation = linalg.QUATERNIONF32_IDENTITY,
          mass = 50,
        )
        idx += 1
      }
    }
  }

  // Simulate for 200 steps at 60 FPS (dt = 1/60)
  dt :: 1.0 / 60.0

  for step in 0 ..< 1000 {
    physics.step(&physics_world, dt)

    // Log cube positions periodically to debug
    if step % 100 == 0 {
      contact_count := len(physics_world.contacts)
      fmt.printf("\n=== Step %d, %d contacts ===\n", step, contact_count)
      for handle, i in cube_handles {
        if body, ok := physics.get_body(&physics_world, handle); ok {
          fmt.printf("  Cube %d: pos=(%.3f,%.3f,%.3f) vel=%.3f angvel=%.3f\n",
            i, body.position.x, body.position.y, body.position.z,
            linalg.length(body.velocity), linalg.length(body.angular_velocity))
        } else {
          fmt.printf("  Cube %d: REMOVED\n", i)
        }
      }
      // Log some contact details
      if contact_count > 0 && step >= 200 {
        fmt.printf("  Sample contacts:\n")
        for contact, idx in physics_world.contacts {
          if idx >= 3 do break // Just show first 3
          fmt.printf("    [%d] penetration=%.4f normal=(%.2f,%.2f,%.2f)\n",
            idx, contact.penetration, contact.normal.x, contact.normal.y, contact.normal.z)
        }
      }
    }
  }

  // Check final state - no cubes should sink below ground
  // Ground surface is at y=0, cubes have half_extent=1
  // So cube center should be at minimum y=1.0 (resting on ground)
  sinking_threshold :: 0.0 // If center is below ground surface, it's sinking
  velocity_threshold :: 0.1 // Max velocity for "at rest" (m/s)
  angular_velocity_threshold :: 0.1 // Max angular velocity for "at rest" (rad/s)

  // Check cubes that are still alive (some may have fallen below KILL_Y threshold)
  alive_cubes := 0
  settled_cubes := 0
  for handle, i in cube_handles {
    body, ok := physics.get_body(&physics_world, handle)
    if !ok {
      // Cube fell below KILL_Y threshold and was removed - this is expected
      continue
    }
    alive_cubes += 1

    linear_vel := linalg.length(body.velocity)
    angular_vel := linalg.length(body.angular_velocity)

    fmt.printf("Cube %d: pos=(%.3f,%.3f,%.3f) vel=%.3f angvel=%.3f\n",
      i, body.position.x, body.position.y, body.position.z, linear_vel, angular_vel)

    // Check not sinking
    testing.expectf(
      t,
      body.position.y >= sinking_threshold,
      "Cube %d SANK! Position: %v, Expected y >= %.3f",
      i,
      body.position,
      sinking_threshold,
    )

    // Check if settled (at rest)
    if linear_vel < velocity_threshold && angular_vel < angular_velocity_threshold {
      settled_cubes += 1
    }
  }

  // Log final statistics
  final_contacts := len(physics_world.contacts)
  fmt.printf("Final state: %d contacts, %d/%d cubes alive/settled\n",
    final_contacts, alive_cubes, settled_cubes)

  testing.expectf(
    t,
    alive_cubes >= 9,
    "Expected at least 9 cubes to survive, got %d",
    alive_cubes,
  )

  testing.expectf(
    t,
    settled_cubes >= 9,
    "Expected at least 9 cubes to settle (vel < %.2f, angvel < %.2f), got %d settled",
    velocity_threshold,
    angular_velocity_threshold,
    settled_cubes,
  )
}
