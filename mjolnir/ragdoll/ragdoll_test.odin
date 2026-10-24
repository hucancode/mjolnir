#+build !js
#+private
package ragdoll

import "../animation"
import "../physics"
import "core:math/linalg"
import "core:testing"

@(private = "file")
Fixture :: struct {
  skeleton: animation.Skeleton,
  blocks:   [2]Block,
  ragdoll:  Ragdoll,
  world:    physics.World,
}

// Three bones stacked on Y at 0, 1 and 2; one block per segment, hip bone as the root.
@(private = "file")
fixture_init :: proc(f: ^Fixture) -> bool {
  parents := []i32{-1, 0, 1}
  inverse_bind: [3]matrix[4, 4]f32
  for i in 0 ..< 3 do inverse_bind[i] = linalg.matrix4_translate([3]f32{0, -f32(i), 0})
  animation.skeleton_init(&f.skeleton, parents, inverse_bind[:]) or_return
  f.blocks = {
    {name = "low", start = 0, end = 1, parent = -1, size = {0.2, 0, 0.2}},
    {name = "high", start = 1, end = 2, parent = 0, joint = .BALL, size = {0.15, 0, 0.15}},
  }
  init(&f.ragdoll, &f.skeleton, f.blocks[:]) or_return
  physics.init(&f.world, thread_count = 1)
  return true
}

@(private = "file")
fixture_destroy :: proc(f: ^Fixture) {
  despawn(&f.ragdoll, &f.world)
  physics.shutdown(&f.world)
  destroy(&f.ragdoll)
  animation.skeleton_destroy(&f.skeleton)
}

@(test)
test_bones_follow_nearest_block :: proc(t: ^testing.T) {
  f: Fixture
  testing.expect(t, fixture_init(&f))
  defer fixture_destroy(&f)
  testing.expect_value(t, f.ragdoll.owner[0], 0)
  testing.expect_value(t, f.ragdoll.owner[1], 1)
  testing.expect_value(t, f.ragdoll.owner[2], 1)
}

@(test)
test_init_rejects_bad_blocks :: proc(t: ^testing.T) {
  f: Fixture
  testing.expect(t, fixture_init(&f))
  defer fixture_destroy(&f)
  other: Ragdoll
  bad := []Block{{start = 0, end = 7}}
  testing.expect(t, !init(&other, &f.skeleton, bad), "bone index out of range")
  same := []Block{{start = 1, end = 1}}
  testing.expect(t, !init(&other, &f.skeleton, same), "coinciding bones")
}

@(test)
test_static_spawn_keeps_rest_pose :: proc(t: ^testing.T) {
  f: Fixture
  testing.expect(t, fixture_init(&f))
  defer fixture_destroy(&f)
  spawn(&f.ragdoll, &f.world, {3, 0, 0}, simulate = false)
  palette: [3]matrix[4, 4]f32
  origin, ok := sync(&f.ragdoll, &f.world, palette[:])
  testing.expect(t, ok)
  testing.expect(t, linalg.length(origin - [3]f32{3, 0, 0}) < 1e-4, "origin should be where it was spawned")
  for m in palette do for c in 0 ..< 4 do for r in 0 ..< 4 {
    want: f32 = 1 if r == c else 0
    testing.expect(t, abs(m[r, c] - want) < 1e-4, "static ragdoll must leave the mesh in its rest pose")
  }
}

@(test)
test_simulated_pose_keeps_joint_closed :: proc(t: ^testing.T) {
  f: Fixture
  testing.expect(t, fixture_init(&f))
  defer fixture_destroy(&f)
  f.world.gravity = {0, -9.81, 0}
  physics.body_create(&f.world, {0, -0.5, 0}, collider = physics.BoxCollider{half_extents = {20, 0.5, 20}})
  spawn(&f.ragdoll, &f.world, {0, ground_height(&f.ragdoll) + 1, 0})
  palette: [3]matrix[4, 4]f32
  for _ in 0 ..< 90 do physics.step(&f.world, 1.0 / 60.0)
  _, ok := sync(&f.ragdoll, &f.world, palette[:])
  testing.expect(t, ok)
  // Bone 1 is where both blocks meet: the lower block carries bone 0, the upper bone 1 and 2.
  joint_low := palette[0] * f.skeleton.bind[0] * [4]f32{0, 1, 0, 1}
  joint_high := palette[1] * f.skeleton.bind[1] * [4]f32{0, 0, 0, 1}
  testing.expect(t, linalg.length(joint_low.xyz - joint_high.xyz) < 0.05, "blocks came apart at their joint")
  moved := palette[2] != linalg.MATRIX4F32_IDENTITY
  testing.expect(t, moved, "simulating must move the pose")
}

@(test)
test_spawn_replaces_and_despawn_frees :: proc(t: ^testing.T) {
  f: Fixture
  testing.expect(t, fixture_init(&f))
  defer fixture_destroy(&f)
  spawn(&f.ragdoll, &f.world, {})
  first := body(&f.ragdoll, 0)
  spawn(&f.ragdoll, &f.world, {})
  _, stale := physics.body(&f.world, first)
  testing.expect(t, !stale, "a second spawn must free the first bodies")
  handle := body(&f.ragdoll, 1)
  block, ok := block_of(&f.ragdoll, handle)
  testing.expect(t, ok && block == 1)
  despawn(&f.ragdoll, &f.world)
  _, alive := physics.body(&f.world, handle)
  testing.expect(t, !alive, "despawn must free the bodies")
  testing.expect_value(t, body(&f.ragdoll, 0), physics.BodyHandle{})
}
