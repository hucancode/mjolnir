#+build !js
#+private
package animation

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

// Straight chain along +Y with identity rotations, so each bone's Y axis
// points along its segment (what the constraint cones are measured against).
@(private = "file")
up_chain :: proc(n: int) -> (positions: [][3]f32, rotations: []quaternion128) {
  positions = make([][3]f32, n, context.temp_allocator)
  rotations = make([]quaternion128, n, context.temp_allocator)
  for i in 0 ..< n {
    positions[i] = {0, f32(i), 0}
    rotations[i] = linalg.QUATERNIONF32_IDENTITY
  }
  return
}

// A pose over a chain of `len(positions)` bones, each the parent of the next, `spacing` long.
@(private = "file")
chain_pose :: proc(positions: [][3]f32, rotations: []quaternion128, spacing: f32 = 1, limits: []JointLimit = nil, allocator := context.temp_allocator) -> Pose {
  n := len(positions)
  parents := make([]i32, n, allocator)
  order := make([]u32, n, allocator)
  lengths := make([]f32, n, allocator)
  for i in 0 ..< n {
    parents[i] = i32(i) - 1
    order[i] = u32(i)
    lengths[i] = abs(spacing) if i > 0 else 0
  }
  return Pose{positions = positions, rotations = rotations, parents = parents, order = order, lengths = lengths, limits = limits, root_world = linalg.MATRIX4F32_IDENTITY, root_inv = linalg.MATRIX4F32_IDENTITY}
}

// Limits for a chain: the root gets `root_max`, the rest `rest_max`.
@(private = "file")
uniform_limits :: proc(n: int, root_max, rest_max: [3]f32) -> []JointLimit {
  out := make([]JointLimit, n, context.temp_allocator)
  out[0] = {root_max}
  for i in 1 ..< n do out[i] = {rest_max}
  return out
}

@(private = "file")
indices :: proc(n: int) -> []u32 {
  out := make([]u32, n, context.temp_allocator)
  for i in 0 ..< n do out[i] = u32(i)
  return out
}

@(private = "file")
has_nan :: proc(v: [3]f32) -> bool {
  return math.is_nan(v.x) || math.is_nan(v.y) || math.is_nan(v.z)
}

@(test)
test_fabrik_two_bone_straight_reach :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(3)
  target := [3]f32{1, -1.5, 0}
  ik_solve(chain_pose(positions, rotations), indices(3), target, linalg.VECTOR3F32_Z_AXIS, 1, 20, 0.001)
  testing.expectf(t, linalg.distance(positions[2], target) < 0.01, "end reaches target, got %v", positions[2])
  testing.expectf(t, math.abs(linalg.distance(positions[0], positions[1]) - 1) < 0.01, "upper length kept")
  testing.expectf(t, math.abs(linalg.distance(positions[1], positions[2]) - 1) < 0.01, "lower length kept")
}

@(test)
test_fabrik_unreachable_target :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(3)
  target := [3]f32{3, 0, 0}
  ik_solve(chain_pose(positions, rotations), indices(3), target, linalg.VECTOR3F32_Z_AXIS, 1, 20, 0.001)
  reach := linalg.distance(positions[0], positions[2])
  testing.expectf(t, reach <= 2.0 && reach >= 1.99, "chain at max reach (~2.0): %f", reach)
  dot := linalg.dot(linalg.normalize(positions[2] - positions[0]), linalg.normalize(target - positions[0]))
  testing.expectf(t, dot > 0.99, "chain points toward target, dot %f", dot)
}

@(test)
test_fabrik_four_bone_chain :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(5)
  target := [3]f32{2, -3, 0}
  ik_solve(chain_pose(positions, rotations), indices(5), target, {0, -2, 1}, 1, 20, 0.001)
  testing.expectf(t, linalg.distance(positions[4], target) < 0.02, "end reaches target, got %v", positions[4])
  for i in 0 ..< 4 {
    length := linalg.distance(positions[i], positions[i + 1])
    testing.expectf(t, math.abs(length - 1.0) < 0.01, "bone %d length kept: %f", i, length)
  }
}

@(test)
test_fabrik_pole_vector :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(4)
  target := [3]f32{1.5, -2, 0}
  ik_solve(chain_pose(positions, rotations), indices(4), target, {0, -1, 2}, 1, 20, 0.001)
  testing.expectf(t, positions[1].z > -0.1 || positions[2].z > -0.1, "a middle joint bends toward the pole: %f, %f", positions[1].z, positions[2].z)
  testing.expectf(t, linalg.distance(positions[3], target) < 0.02, "end reaches target")
}

@(test)
test_fabrik_convergence :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(6, 0.5)
  target := [3]f32{1, -2, 0}
  ik_solve(chain_pose(positions, rotations, 0.5), indices(6), target, linalg.VECTOR3F32_Z_AXIS, 1, 30, 0.0001)
  testing.expectf(t, linalg.distance(positions[5], target) < 0.001, "converges, off by %f", linalg.distance(positions[5], target))
}

@(test)
bench_fabrik_solve :: proc(t: ^testing.T) {
	bench_fabrik_state :: struct {
		pose: Pose,
		bones: []u32,
	}
	state: bench_fabrik_state
	opts := time.Benchmark_Options {
		rounds   = 10_000,
		setup    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_fabrik_state)opts.user_data
			N :: 6
			positions, rotations := straight_chain(N, -1, context.allocator)
			s.pose = chain_pose(positions, rotations, -1, allocator = context.allocator)
			s.bones = make([]u32, N)
			for i in 0 ..< N do s.bones[i] = u32(i)
			return .Okay
		},
		bench    = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_fabrik_state)opts.user_data
			for _ in 0 ..< opts.rounds {
				ik_solve(s.pose, s.bones, {2.5, 3.0, 1.0}, {1, 0, 0}, 0.5, 10, 0.01)
				free_all(context.temp_allocator)
			}
			opts.count = opts.rounds
			return .Okay
		},
		teardown = proc(opts: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
			s := cast(^bench_fabrik_state)opts.user_data
			delete(s.pose.positions)
			delete(s.pose.rotations)
			delete(s.pose.parents)
			delete(s.pose.order)
			delete(s.pose.lengths)
			delete(s.bones)
			return .Okay
		},
		user_data = &state,
	}
	err := time.benchmark(&opts)
	testing.expect(t, err == .Okay, "bench failed")
	log.infof("ik_solve N=6 max_iter=10, %d rounds in %v, %.0f rounds/sec",
		opts.rounds, opts.duration, opts.rounds_per_second)
}

// pose_blend after a solve lands between the incoming pose and the solved one, keeping bone
// lengths and slerping rotations.
@(test)
test_pose_blend_ik_between_fk_and_ik :: proc(t: ^testing.T) {
  target := [3]f32{1.5, 1.5, 0}
  full_pos, full_rot := up_chain(4)
  ik_solve(chain_pose(full_pos, full_rot), indices(4), target, iterations = 30)
  testing.expectf(t, linalg.distance(full_pos[3], target) < 0.01, "full IK reaches, got %v", full_pos[3])
  fk_pos, fk_rot := up_chain(4)
  for w in ([]f32{0.25, 0.5, 0.75}) {
    pos, rot := up_chain(4)
    pose := chain_pose(pos, rot)
    ik_solve(pose, indices(4), target, iterations = 30)
    pose_blend(pose, indices(4), fk_pos, fk_rot, w)
    testing.expect(t, pos[0] == fk_pos[0], "root stays at FK")
    for i in 1 ..< 4 {
      l := linalg.distance(pos[i], pos[i - 1])
      testing.expectf(t, math.abs(l - 1) < 1e-3, "w=%v bone %d length %f", w, i, l)
    }
    d_fk := linalg.distance(pos[3], fk_pos[3])
    d_ik := linalg.distance(pos[3], full_pos[3])
    testing.expectf(t, d_fk > 0.05 && d_ik > 0.05, "w=%v tip strictly between FK and IK (%f, %f)", w, d_fk, d_ik)
    for i in 0 ..< 4 {
      q := linalg.quaternion_slerp(linalg.QUATERNIONF32_IDENTITY, full_rot[i], w)
      testing.expectf(t, almost_equal_quaternion(rot[i], q, 1e-4), "w=%v bone %d rotation slerped", w, i)
    }
  }
}

@(test)
test_fabrik_target_on_root_no_nan :: proc(t: ^testing.T) {
  pos, rot := up_chain(3)
  ik_solve(chain_pose(pos, rot), indices(3), {0, 0, 0}, {0, 0, 5}, 1)
  for p in pos do testing.expectf(t, !has_nan(p), "no NaN, got %v", pos)
  // coincident joints in the FK pose
  pos2, rot2 := up_chain(3)
  pos2[1] = pos2[0]
  ik_solve(chain_pose(pos2, rot2), indices(3), {1, 1, 0})
  for p in pos2 do testing.expectf(t, !has_nan(p), "no NaN with coincident joints, got %v", pos2)
}

@(test)
test_fabrik_unreachable_constrained_aims_at_target :: proc(t: ^testing.T) {
  pos, rot := up_chain(4)
  deg30 := f32(math.PI / 6)
  limits := []JointLimit{{{deg30, -1, deg30}}, JOINT_FREE, JOINT_FREE, JOINT_FREE}
  target := [3]f32{10, 0, 0}
  ik_solve(chain_pose(pos, rot, limits = limits), indices(4), target)
  seg := linalg.normalize(pos[3] - pos[2])
  to_target := linalg.normalize(target - pos[2])
  testing.expectf(t, linalg.dot(seg, to_target) > 0.9999, "last segment points at target: seg %v want %v", seg, to_target)
  root_dir := linalg.normalize(pos[1] - pos[0])
  testing.expectf(t, linalg.dot(root_dir, [3]f32{0, 1, 0}) > math.cos(deg30) - 1e-4, "root still within its 30 deg cone, dir %v", root_dir)
}

@(test)
test_fabrik_constraint_cone_follows_parent :: proc(t: ^testing.T) {
  // Each joint bends 20 deg relative to its parent: reachable with 30 deg cones only
  // if the child's cone turns with the parent (the tip segment is 60 deg off +Y).
  deg30 := f32(math.PI / 6)
  target: [3]f32
  for k in 1 ..= 3 {
    a := f32(k) * math.PI / 9
    target += {math.sin(a), math.cos(a), 0}
  }
  pos, rot := up_chain(4)
  limits := uniform_limits(4, {deg30, -1, deg30}, {deg30, -1, deg30})
  ik_solve(chain_pose(pos, rot, limits = limits), indices(4), target, iterations = 100)
  d := linalg.distance(pos[3], target)
  testing.expectf(t, d < 0.02, "reaches a target needing 60 deg total bend, off by %f (tip %v target %v)", d, pos[3], target)
}

@(test)
test_fabrik_constrained_folds_back :: proc(t: ^testing.T) {
  // Target just above the root-side of a straight chain: the last bones must fold
  // back past 90 deg of their FK direction in steps no bone's 100 deg cone forbids.
  // Clamping only in the root-to-tip pass stalls here.
  pos, rot := up_chain(5)
  lim := f32(math.to_radians(f32(100)))
  limits := uniform_limits(5, {lim, -1, lim}, {lim, -1, lim})
  target := [3]f32{0.8, 2.2, 0}
  ik_solve(chain_pose(pos, rot, limits = limits), indices(5), target, iterations = 30)
  d := linalg.distance(pos[4], target)
  testing.expectf(t, d < 0.01, "folded chain reaches target, off by %f (tip %v)", d, pos[4])
}
