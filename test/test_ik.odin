package tests

import "../mjolnir/animation"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"

// Test two-bone IK with a simple straight configuration
@(test)
test_two_bone_ik_straight_reach :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  // Setup: Two bones pointing straight down (Y axis)
  // Root at origin, middle at (0,-1,0), end at (0,-2,0)
  world_transforms := make([]animation.BoneTransform, 3)
  defer delete(world_transforms)

  // Initial FK positions (straight down)
  world_transforms[0] = animation.BoneTransform {
    world_position = [3]f32{0, 0, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.MATRIX4F32_IDENTITY,
  }
  world_transforms[1] = animation.BoneTransform {
    world_position = [3]f32{0, -1, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.matrix4_translate([3]f32{0, -1, 0}),
  }
  world_transforms[2] = animation.BoneTransform {
    world_position = [3]f32{0, -2, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.matrix4_translate([3]f32{0, -2, 0}),
  }

  // IK target: reach to (1, -1.5, 0) - reachable within chain length
  target := animation.TwoBoneIKTarget {
    root_bone_idx   = 0,
    middle_bone_idx = 1,
    end_bone_idx    = 2,
    target_position = [3]f32{1, -1.5, 0},
    pole_vector     = [3]f32{0, 0, 1}, // Bend toward +Z
    weight          = 1.0,
    enabled         = true,
  }

  bone_lengths := [2]f32{1.0, 1.0} // Each bone is length 1

  // Apply IK
  animation.two_bone_ik_solve(world_transforms[:], target, bone_lengths)

  // Verify end effector reached target (within tolerance)
  end_pos := world_transforms[2].world_position
  dist := linalg.distance(end_pos, target.target_position)

  testing.expect(
    t,
    dist < 0.01,
    fmt.tprintf(
      "End effector should reach target. Distance: %f, End pos: %v, Target: %v",
      dist,
      end_pos,
      target.target_position,
    ),
  )

  // Verify bone lengths are preserved
  mid_pos := world_transforms[1].world_position
  root_pos := world_transforms[0].world_position

  upper_length := linalg.distance(root_pos, mid_pos)
  lower_length := linalg.distance(mid_pos, end_pos)

  testing.expect(
    t,
    math.abs(upper_length - 1.0) < 0.01,
    fmt.tprintf("Upper bone length should be preserved: %f", upper_length),
  )
  testing.expect(
    t,
    math.abs(lower_length - 1.0) < 0.01,
    fmt.tprintf("Lower bone length should be preserved: %f", lower_length),
  )
}

// Test two-bone IK with an unreachable target (should clamp to max reach)
@(test)
test_two_bone_ik_unreachable_target :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  world_transforms := make([]animation.BoneTransform, 3)
  defer delete(world_transforms)

  // Initial FK positions
  world_transforms[0] = animation.BoneTransform {
    world_position = [3]f32{0, 0, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.MATRIX4F32_IDENTITY,
  }
  world_transforms[1] = animation.BoneTransform {
    world_position = [3]f32{0, -1, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.matrix4_translate([3]f32{0, -1, 0}),
  }
  world_transforms[2] = animation.BoneTransform {
    world_position = [3]f32{0, -2, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.matrix4_translate([3]f32{0, -2, 0}),
  }

  // Target beyond max reach (bone lengths are 1+1=2, target at distance 3)
  target := animation.TwoBoneIKTarget {
    root_bone_idx   = 0,
    middle_bone_idx = 1,
    end_bone_idx    = 2,
    target_position = [3]f32{3, 0, 0},
    pole_vector     = [3]f32{0, 0, 1},
    weight          = 1.0,
    enabled         = true,
  }

  bone_lengths := [2]f32{1.0, 1.0}

  animation.two_bone_ik_solve(world_transforms[:], target, bone_lengths)

  // Verify chain is stretched toward target but not beyond max reach
  end_pos := world_transforms[2].world_position
  root_pos := world_transforms[0].world_position
  reach := linalg.distance(root_pos, end_pos)

  testing.expect(
    t,
    reach <= 2.0 && reach >= 1.99,
    fmt.tprintf("Chain should be at max reach (~2.0): %f", reach),
  )

  // Verify chain points toward target
  to_end := linalg.normalize(end_pos - root_pos)
  to_target := linalg.normalize(target.target_position - root_pos)
  dot := linalg.dot(to_end, to_target)

  testing.expect(
    t,
    dot > 0.99,
    fmt.tprintf("Chain should point toward target. Dot product: %f", dot),
  )
}

// Test two-bone IK with right-angle bend
@(test)
test_two_bone_ik_right_angle_bend :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  world_transforms := make([]animation.BoneTransform, 3)
  defer delete(world_transforms)

  // Initial FK positions (straight down)
  world_transforms[0] = animation.BoneTransform {
    world_position = [3]f32{0, 0, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.MATRIX4F32_IDENTITY,
  }
  world_transforms[1] = animation.BoneTransform {
    world_position = [3]f32{0, -1, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.matrix4_translate([3]f32{0, -1, 0}),
  }
  world_transforms[2] = animation.BoneTransform {
    world_position = [3]f32{0, -2, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.matrix4_translate([3]f32{0, -2, 0}),
  }

  // Target that requires ~90 degree bend at middle joint
  // With bone lengths 1,1, target at (sqrt(2)/2, -sqrt(2)/2, 0) ≈ (0.707, -0.707, 0)
  sqrt2 := math.sqrt_f32(2.0)
  target := animation.TwoBoneIKTarget {
    root_bone_idx   = 0,
    middle_bone_idx = 1,
    end_bone_idx    = 2,
    target_position = [3]f32{sqrt2 / 2, -sqrt2 / 2, 0},
    pole_vector     = [3]f32{0, 0, 1},
    weight          = 1.0,
    enabled         = true,
  }

  bone_lengths := [2]f32{1.0, 1.0}

  animation.two_bone_ik_solve(world_transforms[:], target, bone_lengths)

  // Verify end reached target
  end_pos := world_transforms[2].world_position
  dist := linalg.distance(end_pos, target.target_position)

  testing.expect(
    t,
    dist < 0.01,
    fmt.tprintf("End effector should reach target. Distance: %f", dist),
  )

  // Verify bone lengths preserved
  mid_pos := world_transforms[1].world_position
  root_pos := world_transforms[0].world_position

  upper_length := linalg.distance(root_pos, mid_pos)
  lower_length := linalg.distance(mid_pos, end_pos)

  testing.expect(
    t,
    math.abs(upper_length - 1.0) < 0.01,
    fmt.tprintf("Upper bone length preserved: %f", upper_length),
  )
  testing.expect(
    t,
    math.abs(lower_length - 1.0) < 0.01,
    fmt.tprintf("Lower bone length preserved: %f", lower_length),
  )
}

// Test pole vector influence on bending direction
@(test)
test_two_bone_ik_pole_vector :: proc(t: ^testing.T) {
  testing.set_fail_timeout(t, 30 * time.Second)

  world_transforms := make([]animation.BoneTransform, 3)
  defer delete(world_transforms)

  // Initial positions
  world_transforms[0] = animation.BoneTransform {
    world_position = [3]f32{0, 0, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.MATRIX4F32_IDENTITY,
  }
  world_transforms[1] = animation.BoneTransform {
    world_position = [3]f32{0, -1, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.matrix4_translate([3]f32{0, -1, 0}),
  }
  world_transforms[2] = animation.BoneTransform {
    world_position = [3]f32{0, -2, 0},
    world_rotation = linalg.QUATERNIONF32_IDENTITY,
    world_matrix   = linalg.matrix4_translate([3]f32{0, -2, 0}),
  }

  // Target with pole pointing +Z
  target := animation.TwoBoneIKTarget {
    root_bone_idx   = 0,
    middle_bone_idx = 1,
    end_bone_idx    = 2,
    target_position = [3]f32{1, -1, 0},
    pole_vector     = [3]f32{0, 0, 1}, // Bend toward +Z
    weight          = 1.0,
    enabled         = true,
  }

  bone_lengths := [2]f32{1.0, 1.0}

  animation.two_bone_ik_solve(world_transforms[:], target, bone_lengths)

  // Middle joint should have positive Z component (bent toward pole)
  mid_pos := world_transforms[1].world_position

  testing.expect(
    t,
    mid_pos.z > 0,
    fmt.tprintf("Middle joint should bend toward pole (+Z). Z: %f", mid_pos.z),
  )
}
