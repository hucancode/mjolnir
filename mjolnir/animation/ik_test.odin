#+build !js
#+private
package animation

import "../geometry"
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
up_chain :: proc(n: int, allocator := context.temp_allocator) -> (positions: [][3]f32, rotations: []quaternion128) {
  positions = make([][3]f32, n, allocator)
  rotations = make([]quaternion128, n, allocator)
  for i in 0 ..< n {
    positions[i] = {0, f32(i), 0}
    rotations[i] = linalg.QUATERNIONF32_IDENTITY
  }
  return
}

// A pose over a chain of `len(positions)` bones, each the parent of the next, `spacing` long; its
// rest and local transforms are the chain as given.
@(private = "file")
chain_pose :: proc(positions: [][3]f32, rotations: []quaternion128, spacing: f32 = 1, limits: []JointLimit = nil, allocator := context.temp_allocator) -> Pose {
  n := len(positions)
  parents := make([]i32, n, allocator)
  order := make([]u32, n, allocator)
  lengths := make([]f32, n, allocator)
  rest := make([]geometry.Transform, n, allocator)
  local := make([]geometry.Transform, n, allocator)
  scales := make([][3]f32, n, allocator)
  for i in 0 ..< n {
    parents[i] = i32(i) - 1
    order[i] = u32(i)
    lengths[i] = abs(spacing) if i > 0 else 0
    scales[i] = 1
    rest[i] = {positions[i], rotations[i], 1}
    if i > 0 {
      inv := linalg.quaternion_inverse(rotations[i - 1])
      rest[i] = {linalg.mul(inv, positions[i] - positions[i - 1]), inv * rotations[i], 1}
    }
    local[i] = rest[i]
  }
  return Pose{local = local, positions = positions, rotations = rotations, scales = scales, parents = parents, order = order, lengths = lengths, rest = rest, limits = limits, root_world = linalg.MATRIX4F32_IDENTITY, root_inv = linalg.MATRIX4F32_IDENTITY}
}

// Hinge limits for a chain: every joint turns about x only, within lo..hi.
@(private = "file")
hinge_limits :: proc(n: int, lo, hi: f32) -> []JointLimit {
  out := make([]JointLimit, n, context.temp_allocator)
  for &l in out do l = {{lo, 0, 0}, {hi, 0, 0}}
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
  ik_solve(chain_pose(positions, rotations), indices(3), {target = target, pole = linalg.VECTOR3F32_Z_AXIS, pole_weight = 1, iterations = 20, tolerance = 0.001})
  testing.expectf(t, linalg.distance(positions[2], target) < 0.01, "end reaches target, got %v", positions[2])
  testing.expectf(t, math.abs(linalg.distance(positions[0], positions[1]) - 1) < 0.01, "upper length kept")
  testing.expectf(t, math.abs(linalg.distance(positions[1], positions[2]) - 1) < 0.01, "lower length kept")
}

@(test)
test_fabrik_unreachable_target :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(3)
  target := [3]f32{3, 0, 0}
  ik_solve(chain_pose(positions, rotations), indices(3), {target = target, pole = linalg.VECTOR3F32_Z_AXIS, pole_weight = 1, iterations = 20, tolerance = 0.001})
  reach := linalg.distance(positions[0], positions[2])
  testing.expectf(t, reach <= 2.0 && reach >= 1.99, "chain at max reach (~2.0): %f", reach)
  dot := linalg.dot(linalg.normalize(positions[2] - positions[0]), linalg.normalize(target - positions[0]))
  testing.expectf(t, dot > 0.99, "chain points toward target, dot %f", dot)
}

@(test)
test_fabrik_four_bone_chain :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(5)
  target := [3]f32{2, -3, 0}
  ik_solve(chain_pose(positions, rotations), indices(5), {target = target, pole = {0, -2, 1}, pole_weight = 1, iterations = 20, tolerance = 0.001})
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
  ik_solve(chain_pose(positions, rotations), indices(4), {target = target, pole = {0, -1, 2}, pole_weight = 1, iterations = 20, tolerance = 0.001})
  testing.expectf(t, positions[1].z > -0.1 || positions[2].z > -0.1, "a middle joint bends toward the pole: %f, %f", positions[1].z, positions[2].z)
  testing.expectf(t, linalg.distance(positions[3], target) < 0.02, "end reaches target")
}

@(test)
test_fabrik_convergence :: proc(t: ^testing.T) {
  positions, rotations := straight_chain(6, 0.5)
  target := [3]f32{1, -2, 0}
  ik_solve(chain_pose(positions, rotations, 0.5), indices(6), {target = target, pole = linalg.VECTOR3F32_Z_AXIS, pole_weight = 1, iterations = 30, tolerance = 0.0001})
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
				ik_solve(s.pose, s.bones, {target = {2.5, 3.0, 1.0}, pole = {1, 0, 0}, pole_weight = 0.5, iterations = 10, tolerance = 0.01})
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
			delete(s.pose.rest)
			delete(s.pose.local)
			delete(s.pose.scales)
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
  ik_solve(chain_pose(full_pos, full_rot), indices(4), {target = target, iterations = 30})
  testing.expectf(t, linalg.distance(full_pos[3], target) < 0.01, "full IK reaches, got %v", full_pos[3])
  fk_pos, fk_rot := up_chain(4)
  for w in ([]f32{0.25, 0.5, 0.75}) {
    pos, rot := up_chain(4)
    pose := chain_pose(pos, rot)
    ik_solve(pose, indices(4), {target = target, iterations = 30})
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
  ik_solve(chain_pose(pos, rot), indices(3), {target = {0, 0, 0}, pole = {0, 0, 5}, pole_weight = 1})
  for p in pos do testing.expectf(t, !has_nan(p), "no NaN, got %v", pos)
  // coincident joints in the FK pose
  pos2, rot2 := up_chain(3)
  pos2[1] = pos2[0]
  ik_solve(chain_pose(pos2, rot2), indices(3), {target = {1, 1, 0}})
  for p in pos2 do testing.expectf(t, !has_nan(p), "no NaN with coincident joints, got %v", pos2)
}

@(test)
test_joint_angles_round_trip :: proc(t: ^testing.T) {
  rest := linalg.quaternion_angle_axis_f32(0.7, linalg.normalize([3]f32{1, 2, 3}))
  for a in ([][3]f32{{0.3, -0.4, 1.2}, {-2.5, 1.1, 0.2}, {0, 0, 3}, {1, 0, 0}}) {
    got := joint_angles(rest, joint_rotation(rest, a, JOINT_FREE))
    testing.expectf(t, linalg.length(got - a) < 1e-4, "angles %v round trip to %v", a, got)
  }
  // stops clamp
  got := joint_angles(rest, joint_rotation(rest, {2, 0, 0}, {{-1, 0, 0}, {1, 0, 0}}))
  testing.expectf(t, abs(got.x - 1) < 1e-4 && abs(got.y) < 1e-4 && abs(got.z) < 1e-4, "clamped to the stop, got %v", got)
}

// A chain of hinges about x reaches a target in its plane and never leaves it.
@(test)
test_ccd_hinge_stays_in_plane :: proc(t: ^testing.T) {
  pos, rot := up_chain(4)
  pose := chain_pose(pos, rot, limits = hinge_limits(4, -2, 2))
  target := [3]f32{0, 2, 1.2}
  ik_solve(pose, indices(4), {target = target, iterations = 30})
  testing.expectf(t, linalg.distance(pos[3], target) < 0.02, "reaches, tip %v", pos[3])
  for p in pos do testing.expectf(t, abs(p.x) < 1e-4, "stays in the hinges' plane, got %v", pos)
  for b in 0 ..< 4 {
    a := joint_angles(pose.rest[b].rotation, pose.local[b].rotation)
    testing.expectf(t, abs(a.y) < 1e-4 && abs(a.z) < 1e-4 && a.x >= -2 - 1e-4 && a.x <= 2 + 1e-4, "bone %d turns about x within its stops, %v", b, a)
  }
}

// Hinges that only bend one way never bend the other, even for a target there.
@(test)
test_ccd_asymmetric_stops :: proc(t: ^testing.T) {
  pos, rot := up_chain(4)
  pose := chain_pose(pos, rot, limits = hinge_limits(4, 0, 2))
  ik_solve(pose, indices(4), {target = {0, 2, -1.2}, iterations = 30})
  for p in pos do testing.expectf(t, p.z > -1e-4 && abs(p.x) < 1e-4, "never bends toward -z, got %v", pos)
  // the other way it reaches
  pos2, rot2 := up_chain(4)
  ik_solve(chain_pose(pos2, rot2, limits = hinge_limits(4, 0, 2)), indices(4), {target = {0, 2, 1.2}, iterations = 30})
  testing.expectf(t, linalg.distance(pos2[3], {0, 2, 1.2}) < 0.02, "reaches the way it bends, tip %v", pos2[3])
}

// `end` reaches with a point past the last bone; `ends` + `hold` keep the end's facing.
@(test)
test_ccd_end_and_hold :: proc(t: ^testing.T) {
  pos, rot := up_chain(4)
  pose := chain_pose(pos, rot, limits = hinge_limits(4, -2.5, 2.5))
  end := [3]f32{0, 0.5, 0}
  target := [3]f32{0, 2.2, 1}
  ik_solve(pose, indices(4), {target = target, iterations = 30, end = end, ends = 1, hold = true})
  tip := pos[3] + linalg.mul(rot[3], end)
  testing.expectf(t, linalg.distance(tip, target) < 0.05, "the end point reaches, got %v", tip)
  testing.expectf(t, almost_equal_quaternion(rot[3], linalg.QUATERNIONF32_IDENTITY, 5e-3), "the end keeps facing as it did, got %v", rot[3])
}

// A middle joint placed by the pole bends toward it.
@(test)
test_ccd_middle_bends_toward_pole :: proc(t: ^testing.T) {
  for side in ([]f32{1, -1}) {
    pos, rot := up_chain(3)
    pose := chain_pose(pos, rot, limits = hinge_limits(3, -2.5, 2.5))
    mid := ik_chain_middle(pose, indices(3), {})
    testing.expect_value(t, mid, 1)
    ik_solve(pose, indices(3), {target = {0, 1.5, 0}, pole = {0, 1, side * 2}, pole_weight = 1, middle = mid, iterations = 16})
    testing.expectf(t, pos[1].z * side > 0.3, "knee toward the pole (side %v), got %v", side, pos[1])
    testing.expectf(t, linalg.distance(pos[2], {0, 1.5, 0}) < 0.02, "reaches, got %v", pos[2])
  }
}

// A partial weight blends a limited chain's turns: it stays on its hinges.
@(test)
test_pose_blend_limited_keeps_hinges :: proc(t: ^testing.T) {
  pos, rot := up_chain(4)
  pose := chain_pose(pos, rot, limits = hinge_limits(4, -2, 2))
  fk_pos, fk_rot := up_chain(4)
  ik_solve(pose, indices(4), {target = {0, 2, 1.2}, iterations = 30})
  solved: [4][3]f32
  for b in 0 ..< 4 do solved[b] = joint_angles(pose.rest[b].rotation, pose.local[b].rotation)
  pose_blend(pose, indices(4), fk_pos, fk_rot, 0.5)
  for b in 0 ..< 4 {
    a := joint_angles(pose.rest[b].rotation, pose.local[b].rotation)
    testing.expectf(t, linalg.length(a - solved[b] * 0.5) < 1e-3, "bone %d half turned: %v of %v", b, a, solved[b])
    testing.expectf(t, abs(pos[b].x) < 1e-4, "bone %d on the hinges' plane, %v", b, pos[b])
  }
}

// aim_solve turns a spin joint (y) so its look points at the target.
@(test)
test_aim_solve_turns_to_look :: proc(t: ^testing.T) {
  pos, rot := up_chain(2)
  pose := chain_pose(pos, rot, limits = []JointLimit{{{0, -3, 0}, {0, 3, 0}}, {{0, 0, 0}, {0, 0, 0}}})
  aim_solve(pose, indices(2), {0, 0, 1}, {}, {5, 1, 0})
  look := linalg.mul(rot[1], [3]f32{0, 0, 1})
  testing.expectf(t, linalg.dot(look, [3]f32{1, 0, 0}) > 0.999, "looks at +x, got %v", look)
}

@(test)
bench_limited_solve :: proc(t: ^testing.T) {
  ROUNDS :: 10_000
  pos, rot := up_chain(4, context.allocator)
  defer delete(pos)
  defer delete(rot)
  pose := chain_pose(pos, rot, limits = hinge_limits(4, -2, 2), allocator = context.allocator)
  start_pos := make([][3]f32, 4)
  defer delete(start_pos)
  copy(start_pos, pos)
  start := time.tick_now()
  for _ in 0 ..< ROUNDS {
    for b in 0 ..< 4 do pose.local[b] = pose.rest[b]
    pose_compose(pose)
    ik_solve(pose, indices(4), {target = {0, 2, 1.2}, iterations = 16, pole = {0, 1, 2}, pole_weight = 1, middle = 2})
    free_all(context.temp_allocator)
  }
  d := time.tick_since(start)
  log.infof("ik_solve limited hinges N=4 iter=16, %d rounds in %v, %.0f rounds/sec", ROUNDS, d, f64(ROUNDS) / time.duration_seconds(d))
  delete(pose.parents)
  delete(pose.order)
  delete(pose.lengths)
  delete(pose.rest)
  delete(pose.local)
  delete(pose.scales)
}

@(test)
test_two_link_reaches :: proc(t: ^testing.T) {
  for target in ([][2]f32{{1.2, 0.3}, {0.5, -0.4}, {0.3, 0.9}}) {
    a, b, reached := two_link(1, 0.8, target)
    testing.expect(t, reached)
    testing.expect(t, b <= 0)
    tip := [2]f32{math.cos(a), math.sin(a)} + 0.8 * [2]f32{math.cos(a + b), math.sin(a + b)}
    testing.expect(t, linalg.length(tip - target) < 1e-4)
  }
  a, b, reached := two_link(1, 0.8, {3, 0})
  testing.expect(t, !reached)
  testing.expect(t, abs(a) < 1e-4 && abs(b) < 1e-4)
}
