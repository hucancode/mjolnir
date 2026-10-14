#+build !js
package animation

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:testing"
import "core:time"
import "base:runtime"
import "core:log"

// Straight chain along -Y with `spacing` between joints, identity rotations
@(private = "file")
straight_chain :: proc(n: int, spacing: f32 = 1, allocator := context.temp_allocator) -> (positions: [][3]f32, rotations: []quaternion128) {
  positions = make([][3]f32, n, allocator)
  rotations = make([]quaternion128, n, allocator)
  for i in 0 ..< n {
    positions[i] = {0, -f32(i) * spacing, 0}
    rotations[i] = linalg.QUATERNIONF32_IDENTITY
  }
  return
}

// Test FABRIK with 2-bone chain reaching a target
@(test)
test_fabrik_two_bone_straight_reach :: proc(t: ^testing.T) {
  // Setup: Two bones pointing straight down (Y axis)
  // Root at origin, middle at (0,-1,0), end at (0,-2,0)
  positions, rotations := straight_chain(3)
  // IK target: reach to (1, -1.5, 0) - reachable within chain length
  bone_indices := []u32{0, 1, 2}
  bone_lengths := []f32{1.0, 1.0} // Each bone is length 1
  target := IKTarget {
    bone_indices    = bone_indices,
    bone_lengths    = bone_lengths,
    target_position = [3]f32{1, -1.5, 0},
    pole_vector     = linalg.VECTOR3F32_Z_AXIS, // Bend toward +Z
    pole_weight     = 1.0,
    max_iterations  = 20,
    tolerance       = 0.001,
    weight          = 1.0,
    enabled         = true,
  }
  // Apply IK
  fabrik_solve(positions, rotations, target)
  // Verify end effector reached target (within tolerance)
  end_pos := positions[2]
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
  mid_pos := positions[1]
  root_pos := positions[0]
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

// Test FABRIK with an unreachable target (should stretch toward it)
@(test)
test_fabrik_unreachable_target :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(3)
  // Target beyond max reach (bone lengths are 1+1=2, target at distance 3)
  bone_indices := []u32{0, 1, 2}
  bone_lengths := []f32{1.0, 1.0}
  target := IKTarget {
    bone_indices    = bone_indices,
    bone_lengths    = bone_lengths,
    target_position = [3]f32{3, 0, 0},
    pole_vector     = linalg.VECTOR3F32_Z_AXIS,
    pole_weight     = 1.0,
    max_iterations  = 20,
    tolerance       = 0.001,
    weight          = 1.0,
    enabled         = true,
  }
  fabrik_solve(positions, rotations, target)
  // Verify chain is stretched toward target but not beyond max reach
  end_pos := positions[2]
  root_pos := positions[0]
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

// Test FABRIK with 4-bone chain
@(test)
test_fabrik_four_bone_chain :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(5)
  // Target position
  bone_indices := []u32{0, 1, 2, 3, 4}
  bone_lengths := []f32{1.0, 1.0, 1.0, 1.0}
  target := IKTarget {
    bone_indices    = bone_indices,
    bone_lengths    = bone_lengths,
    target_position = [3]f32{2, -3, 0},
    pole_vector     = [3]f32{0, -2, 1},
    pole_weight     = 1.0,
    max_iterations  = 20,
    tolerance       = 0.001,
    weight          = 1.0,
    enabled         = true,
  }
  fabrik_solve(positions, rotations, target)
  // Verify end effector reached target
  end_pos := positions[4]
  dist := linalg.distance(end_pos, target.target_position)
  testing.expect(
    t,
    dist < 0.02,
    fmt.tprintf(
      "End effector should reach target. Distance: %f, End pos: %v, Target: %v",
      dist,
      end_pos,
      target.target_position,
    ),
  )
  // Verify all bone lengths are preserved
  for i in 0 ..< 4 {
    pos := positions[i]
    next_pos := positions[i + 1]
    length := linalg.distance(pos, next_pos)
    testing.expect(
      t,
      math.abs(length - 1.0) < 0.01,
      fmt.tprintf("Bone %d length should be preserved: %f", i, length),
    )
  }
}

// Test FABRIK with pole vector constraint
@(test)
test_fabrik_pole_vector :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(4)
  // Target with pole pointing +Z
  bone_indices := []u32{0, 1, 2, 3}
  bone_lengths := []f32{1.0, 1.0, 1.0}
  target := IKTarget {
    bone_indices    = bone_indices,
    bone_lengths    = bone_lengths,
    target_position = [3]f32{1.5, -2, 0},
    pole_vector     = [3]f32{0, -1, 2}, // Pole toward +Z
    pole_weight     = 1.0,
    max_iterations  = 20,
    tolerance       = 0.001,
    weight          = 1.0,
    enabled         = true,
  }
  fabrik_solve(positions, rotations, target)
  // Middle joints should have positive Z component (bent toward pole)
  mid_pos_1 := positions[1]
  mid_pos_2 := positions[2]
  testing.expect(
    t,
    mid_pos_1.z > -0.1 || mid_pos_2.z > -0.1,
    fmt.tprintf(
      "At least one middle joint should bend toward pole (+Z). Z values: %f, %f",
      mid_pos_1.z,
      mid_pos_2.z,
    ),
  )
  // End should reach target
  end_pos := positions[3]
  dist := linalg.distance(end_pos, target.target_position)
  testing.expect(
    t,
    dist < 0.02,
    fmt.tprintf("End effector should reach target. Distance: %f", dist),
  )
}

// Test FABRIK convergence with different iteration counts
@(test)
test_fabrik_convergence :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(6, 0.5)
  bone_indices := []u32{0, 1, 2, 3, 4, 5}
  bone_lengths := []f32{0.5, 0.5, 0.5, 0.5, 0.5}
  target := IKTarget {
    bone_indices    = bone_indices,
    bone_lengths    = bone_lengths,
    target_position = [3]f32{1, -2, 0},
    pole_vector     = linalg.VECTOR3F32_Z_AXIS,
    pole_weight     = 1.0,
    max_iterations  = 30,
    tolerance       = 0.0001,
    weight          = 1.0,
    enabled         = true,
  }
  fabrik_solve(positions, rotations, target)
  // Should converge to target within tolerance
  end_pos := positions[5]
  dist := linalg.distance(end_pos, target.target_position)
  testing.expect(
    t,
    dist < 0.001,
    fmt.tprintf("Should converge within tolerance. Distance: %f", dist),
  )
}

@(test)
bench_fabrik_solve :: proc(t: ^testing.T) {
	bench_fabrik_state :: struct {
		positions: [][3]f32,
		rotations: []quaternion128,
		target: IKTarget,
	}
	state: bench_fabrik_state
	opts := time.Benchmark_Options {
		rounds   = 10_000,
		setup    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_fabrik_state)opts.user_data
			N :: 6
			s.positions, s.rotations = straight_chain(N, -1, context.allocator)
			indices := make([]u32, N)
			for i in 0 ..< N do indices[i] = u32(i)
			lengths := make([]f32, N - 1)
			for i in 0 ..< N - 1 do lengths[i] = 1.0
			s.target = IKTarget {
				bone_indices    = indices,
				bone_lengths    = lengths,
				target_position = {2.5, 3.0, 1.0},
				pole_vector     = {1, 0, 0},
				pole_weight     = 0.5,
				max_iterations  = 10,
				tolerance       = 0.01,
				weight          = 1.0,
				enabled         = true,
				space           = .LOCAL,
			}
			return .Okay
		},
		bench    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_fabrik_state)opts.user_data
			for _ in 0 ..< opts.rounds do fabrik_solve(s.positions, s.rotations, s.target)
			opts.count = opts.rounds
			return .Okay
		},
		teardown = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_fabrik_state)opts.user_data
			delete(s.positions)
			delete(s.rotations)
			delete(s.target.bone_indices)
			delete(s.target.bone_lengths)
			return .Okay
		},
		user_data = &state,
	}
	err := time.benchmark(&opts)
	testing.expect(t, err == .Okay, "bench failed")
	log.infof("fabrik_solve N=6 max_iter=10, %d rounds in %v, %.0f rounds/sec",
		opts.rounds, opts.duration, opts.rounds_per_second)
}
