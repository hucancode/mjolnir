#+build !js
package animation

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:testing"

// 4-bone chain along +Y: root(0,0,0) -> mid(0,1,0) -> tip(0,2,0) -> end(0,3,0).
// Clips:
//   move - root position (0,0,0) -> (10,0,0) over 1s
//   up   - root position constant (0,4,0), 1s
//   bend - root rotation identity -> 90 deg about Z over 1s
//   wave - mid and tip rotation identity -> 90 deg about Z over 1s
make_test_rig :: proc(rig: ^Rig) -> bool {
  inv: [4]matrix[4, 4]f32
  for i in 0 ..< 4 do inv[i] = linalg.matrix4_translate_f32({0, -f32(i), 0})
  names := [4]string{"root", "mid", "tip", "end"}
  parents := [4]i32{-1, 0, 1, 2}
  skeleton_init(&rig.skeleton, parents[:], inv[:], names[:]) or_return
  q90 := linalg.quaternion_angle_axis_f32(math.PI / 2, {0, 0, 1})
  id := linalg.QUATERNIONF32_IDENTITY
  c: Clip
  clip_init(&c, 4, "move")
  clip_set_positions(&c, 0, {0, 1}, {{0, 0, 0}, {10, 0, 0}})
  append(&rig.clips, c)
  c = {}
  clip_init(&c, 4, "up")
  clip_set_positions(&c, 0, {0, 1}, {{0, 4, 0}, {0, 4, 0}})
  append(&rig.clips, c)
  c = {}
  clip_init(&c, 4, "bend")
  clip_set_rotations(&c, 0, {0, 1}, {id, q90})
  append(&rig.clips, c)
  c = {}
  clip_init(&c, 4, "wave")
  clip_set_rotations(&c, 1, {0, 1}, {id, q90})
  clip_set_rotations(&c, 2, {0, 1}, {id, q90})
  append(&rig.clips, c)
  return true
}

model_pos :: proc(a: ^Animator, bone: int) -> [3]f32 {
  return a.positions[bone]
}

@(test)
test_animator_rest_palette_identity :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  testing.expect(t, animator_init(&a, &rig))
  defer animator_destroy(&a)
  testing.expect_value(t, len(a.palette), 4)
  for m in a.palette do testing.expect(t, matrix_almost_equal(m, linalg.MATRIX4F32_IDENTITY))
  testing.expect(t, almost_equal_vec3(model_pos(&a, 3), {0, 3, 0}))
  // no layers: update keeps rest pose
  animator_update(&a, &rig, 0.1)
  for m in a.palette do testing.expect(t, matrix_almost_equal(m, linalg.MATRIX4F32_IDENTITY))
  testing.expect(t, find_clip(&rig, "bend") == 2)
  _, ok := find_clip(&rig, "ghost")
  testing.expect(t, !ok)
}

@(test)
test_animator_play_samples_clip :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  testing.expect(t, play(&a, &rig, "bend"))
  testing.expect(t, !play(&a, &rig, "ghost"), "unknown clip")
  palette := animator_update(&a, &rig, 0.5)
  testing.expect_value(t, len(palette), 4)
  s := math.sin(f32(math.PI / 4))
  testing.expectf(t, almost_equal_vec3(model_pos(&a, 1), {-s, s, 0}), "mid at 45 deg, got %v", model_pos(&a, 1))
  testing.expect(t, almost_equal_vec3(model_pos(&a, 3), {-3 * s, 3 * s, 0}), "end follows")
  q45 := linalg.quaternion_angle_axis_f32(math.PI / 4, {0, 0, 1})
  testing.expect(t, almost_equal_quaternion(a.rotations[2], q45, 1e-4))
  // palette maps bind-pose vertex to posed position
  v := palette[3] * [4]f32{0, 3, 0, 1}
  testing.expect(t, almost_equal_vec3(v.xyz, {-3 * s, 3 * s, 0}), "palette skins end vertex")
  testing.expect(t, matrix_almost_equal(bone_matrix(&a, 2), linalg.matrix4_from_trs(a.positions[2], a.rotations[2], a.scales[2])))
  testing.expect(t, matrix_almost_equal(bone_matrix(&a, 99), linalg.MATRIX4F32_IDENTITY))
}

@(test)
test_animator_once_holds_last_pose :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  play(&a, &rig, "move", .ONCE)
  animator_update(&a, &rig, 0.75)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {7.5, 0, 0}))
  animator_update(&a, &rig, 2)
  fk := a.layers[0].data.(FKLayer)
  testing.expect_value(t, fk.status, Status.STOPPED)
  testing.expect_value(t, fk.time, 1)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {10, 0, 0}))
  animator_update(&a, &rig, 1)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {10, 0, 0}), "holds last pose")
  testing.expect(t, almost_equal_vec3(model_pos(&a, 2), {10, 2, 0}))
}

@(test)
test_animator_layer_weights_blend :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  l0 := add_clip_layer(&a, &rig, "move", 0.5)
  l1 := add_clip_layer(&a, &rig, "up", 0.5)
  testing.expect(t, l0 == 0 && l1 == 1)
  _, ok := add_clip_layer(&a, &rig, "ghost")
  testing.expect(t, !ok)
  animator_update(&a, &rig, 0.5)
  testing.expectf(t, almost_equal_vec3(model_pos(&a, 0), {2.5, 2, 0}), "50/50 blend, got %v", model_pos(&a, 0))
  testing.expect(t, set_layer_weight(&a, 1, 0))
  testing.expect(t, !set_layer_weight(&a, 5, 0))
  animator_update(&a, &rig, 0.25)
  testing.expectf(t, almost_equal_vec3(model_pos(&a, 0), {7.5, 0, 0}), "only move, got %v", model_pos(&a, 0))
  // replace layer at index 0
  testing.expect(t, add_clip_layer(&a, &rig, "up", 1, layer_index = 0) == 0)
  testing.expect_value(t, len(a.layers), 2)
}

@(test)
test_animator_layer_mask :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  play(&a, &rig, "wave")
  mask := bone_mask(&rig.skeleton, []string{"tip"})
  defer delete(mask)
  testing.expect(t, set_layer_mask(&a, 0, mask))
  testing.expect(t, !set_layer_mask(&a, 3, mask))
  animator_update(&a, &rig, 0.5)
  id := linalg.QUATERNIONF32_IDENTITY
  q45 := linalg.quaternion_angle_axis_f32(math.PI / 4, {0, 0, 1})
  testing.expect(t, almost_equal_quaternion(a.local[1].rotation, id), "mid masked out -> rest")
  testing.expect(t, almost_equal_quaternion(a.local[2].rotation, q45, 1e-4), "tip animated")
  testing.expect(t, almost_equal_vec3(model_pos(&a, 2), {0, 2, 0}), "tip position unchanged")
  s := math.sin(f32(math.PI / 4))
  testing.expect(t, almost_equal_vec3(model_pos(&a, 3), {-s, 2 + s, 0}), "end rotated by tip")
}

@(test)
test_animator_transition_to :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  play(&a, &rig, "up")
  testing.expect(t, !transition_to(&a, &rig, "ghost", 1))
  testing.expect(t, transition_to(&a, &rig, "move", 0.5))
  testing.expect_value(t, len(a.layers), 2)
  testing.expect_value(t, a.transition.state, TransitionState.ACTIVE)
  animator_update(&a, &rig, 0.25)
  testing.expect(t, abs(a.layers[0].weight - 0.5) < 1e-5 && abs(a.layers[1].weight - 0.5) < 1e-5)
  testing.expect_value(t, a.transition.state, TransitionState.ACTIVE)
  testing.expectf(t, almost_equal_vec3(model_pos(&a, 0), {1.25, 2, 0}), "mid fade, got %v", model_pos(&a, 0))
  animator_update(&a, &rig, 0.3)
  testing.expect_value(t, a.transition.state, TransitionState.COMPLETE)
  testing.expect(t, a.layers[0].weight == 0 && a.layers[1].weight == 1)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {5.5, 0, 0}), "only target clip")
}

@(test)
test_animator_transition_to_creates_layers :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  testing.expect(t, transition_to(&a, &rig, "move", 0, from = 0, to = 2))
  testing.expect_value(t, len(a.layers), 3)
  animator_update(&a, &rig, 0.5)
  testing.expect_value(t, a.transition.state, TransitionState.COMPLETE)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {5, 0, 0}))
}

@(test)
test_animator_ik_local :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  target := [3]f32{1, 1, 0}
  idx, ok := add_ik_chain_layer(&a, &rig, "root", "tip", target, {1, 0, 0})
  testing.expect(t, ok && idx == 0)
  _, bad := add_ik_chain_layer(&a, &rig, "tip", "root", target, {})
  testing.expect(t, !bad, "inverted chain rejected")
  _, bad2 := add_ik_layer(&a, &rig, []u32{0}, target, {})
  testing.expect(t, !bad2, "single-bone chain rejected")
  animator_update(&a, &rig, 0.016)
  tip := model_pos(&a, 2)
  testing.expectf(t, linalg.distance(tip, target) < 0.01, "tip reaches target, got %v", tip)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {0, 0, 0}), "root fixed")
  testing.expect(t, abs(linalg.distance(model_pos(&a, 1), model_pos(&a, 0)) - 1) < 1e-3, "bone length kept")
  // child of IK-moved tip follows it
  end_expected := (bone_matrix(&a, 2) * [4]f32{0, 1, 0, 1}).xyz
  testing.expectf(t, almost_equal_vec3(model_pos(&a, 3), end_expected), "end follows tip: %v vs %v", model_pos(&a, 3), end_expected)
  testing.expect(t, abs(linalg.distance(model_pos(&a, 3), tip) - 1) < 1e-3)
  // palette consistent with model
  testing.expect(t, matrix_almost_equal(a.palette[3], bone_matrix(&a, 3) * rig.skeleton.inverse_bind[3]))
  // disable -> back to rest
  testing.expect(t, set_ik_enabled(&a, 0, false))
  animator_update(&a, &rig, 0.016)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 2), {0, 2, 0}))
  testing.expect(t, set_ik_enabled(&a, 0, true))
  testing.expect(t, set_ik_target(&a, 0, {-1, 1, 0}, {}))
  animator_update(&a, &rig, 0.016)
  testing.expect(t, linalg.distance(model_pos(&a, 2), [3]f32{-1, 1, 0}) < 0.01)
}

@(test)
test_animator_ik_world_matches_local :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  local, world: Animator
  animator_init(&local, &rig)
  defer animator_destroy(&local)
  animator_init(&world, &rig)
  defer animator_destroy(&world)
  offset := [3]f32{5, -2, 3}
  root_world := linalg.matrix4_translate_f32(offset)
  chain := bone_chain(&rig.skeleton, "root", "tip")
  add_ik_layer(&local, &rig, chain, {1, 1, 0}, {1, 0, 0})
  add_ik_chain_layer(&world, &rig, "root", "tip", [3]f32{1, 1, 0} + offset, [3]f32{1, 0, 0} + offset, space = .WORLD)
  animator_update(&local, &rig, 0.016)
  animator_update(&world, &rig, 0.016, root_world)
  for i in 0 ..< 4 {
    testing.expectf(t, almost_equal_vec3(model_pos(&local, i), model_pos(&world, i)), "bone %d: %v vs %v",
      i, model_pos(&local, i), model_pos(&world, i))
  }
}

@(test)
test_animator_ik_over_clip :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  play(&a, &rig, "move")
  add_ik_chain_layer(&a, &rig, "root", "tip", {6, 1, 0}, {})
  animator_update(&a, &rig, 0.5)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {5, 0, 0}), "FK root")
  testing.expect(t, linalg.distance(model_pos(&a, 2), [3]f32{6, 1, 0}) < 0.01, "IK on top of FK")
}

@(test)
test_animator_remove_and_clear_layers :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  add_clip_layer(&a, &rig, "move")
  add_ik_chain_layer(&a, &rig, "root", "tip", {1, 1, 0}, {})
  add_tail_layer(&a, &rig, "mid", 3)
  testing.expect_value(t, len(a.layers), 3)
  testing.expect(t, remove_layer(&a, 1))
  testing.expect(t, !remove_layer(&a, 7))
  testing.expect_value(t, len(a.layers), 2)
  _, is_proc := a.layers[1].data.(ProceduralLayer)
  testing.expect(t, is_proc, "remaining layers shift down")
  transition_to(&a, &rig, "up", 1)
  clear_layers(&a)
  testing.expect_value(t, len(a.layers), 0)
  testing.expect_value(t, a.transition.state, TransitionState.NONE)
  animator_update(&a, &rig, 0.1)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 3), {0, 3, 0}), "rest after clear")
}

@(test)
test_animator_destroy_frees :: proc(t: ^testing.T) {
  track: mem.Tracking_Allocator
  mem.tracking_allocator_init(&track, context.allocator)
  defer mem.tracking_allocator_destroy(&track)
  {
    context.allocator = mem.tracking_allocator(&track)
    rig: Rig
    make_test_rig(&rig)
    a: Animator
    animator_init(&a, &rig)
    play(&a, &rig, "bend")
    add_ik_chain_layer(&a, &rig, "root", "tip", {1, 1, 0}, {}, constraints = ik_constraints_uniform(3, {1, -1, 1}, {1, -1, 1}))
    add_tail_layer(&a, &rig, "mid", 3)
    path := [][3]f32{{0, 0, 0}, {0, 1, 0}, {1, 2, 0}}
    add_path_layer(&a, &rig, "root", 3, path)
    add_clip_layer(&a, &rig, "move", layer_index = 0) // replace frees old layer
    remove_layer(&a, 1)
    animator_update(&a, &rig, 0.1)
    animator_destroy(&a)
    rig_destroy(&rig)
  }
  testing.expectf(t, len(track.allocation_map) == 0, "leaked %d allocations", len(track.allocation_map))
  testing.expectf(t, len(track.bad_free_array) == 0, "bad frees %d", len(track.bad_free_array))
}

@(test)
test_animator_tail_layer_smoke :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  play(&a, &rig, "bend", .PING_PONG)
  idx, ok := add_tail_layer(&a, &rig, "mid", 3)
  testing.expect(t, ok && idx == 1)
  _, bad := add_tail_layer(&a, &rig, "end", 3)
  testing.expect(t, !bad, "leaf has no chain")
  testing.expect(t, set_tail_params(&a, idx, damping = f32(0.8)))
  testing.expect(t, !set_tail_params(&a, 0, damping = f32(0.8)), "not a tail layer")
  for i in 0 ..< 120 {
    root_world := linalg.matrix4_translate_f32({math.sin(f32(i) * 0.1) * 2, 0, 0})
    animator_update(&a, &rig, 1.0 / 60.0, root_world)
  }
  for m in a.palette do for c in 0 ..< 4 do for r in 0 ..< 4 {
    testing.expect(t, !math.is_nan(m[c][r]) && !math.is_inf(m[c][r]), "finite palette")
  }
  testing.expect(t, abs(linalg.distance(model_pos(&a, 2), model_pos(&a, 1)) - 1) < 0.05, "rigid tail keeps length")
}

@(test)
test_animator_ik_layer_validation :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  // root -> tip skips "mid": not a parent chain
  _, skip := add_ik_layer(&a, &rig, []u32{0, 2}, {0, 2, 0}, {})
  testing.expect(t, !skip, "non-parent chain rejected")
  // constraint count must match the bone count
  bad_cons := []IKBoneConstraint{{}, {}}
  _, mismatch := add_ik_layer(&a, &rig, []u32{0, 1, 2}, {0, 2, 0}, {}, constraints = bad_cons)
  testing.expect(t, !mismatch, "constraint length mismatch rejected")
  idx, ok := add_ik_chain_layer(&a, &rig, "root", "tip", {1, 1, 0}, {1, 0, 0})
  testing.expect(t, ok)
  testing.expect_value(t, a.layers[idx].data.(IKTarget).pole_weight, 1)
}

@(test)
test_animator_ik_layer_weight_blends :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  idx := add_ik_chain_layer(&a, &rig, "root", "tip", {1.5, 0.5, 0}, {})
  animator_update(&a, &rig, 0.016)
  full := a.positions[2]
  set_layer_weight(&a, idx, 0.5)
  animator_update(&a, &rig, 0.016)
  half := a.positions[2]
  testing.expectf(t, linalg.distance(half, full) > 0.05 && linalg.distance(half, [3]f32{0, 2, 0}) > 0.05, "half weight lands between FK and IK: half %v full %v", half, full)
  testing.expectf(t, math.abs(linalg.distance(a.positions[2], a.positions[1]) - 1) < 1e-3, "bone length kept")
  // "end" (child of tip) follows the blended tip
  testing.expectf(t, math.abs(linalg.distance(a.positions[3], a.positions[2]) - 1) < 1e-3, "descendant re-propagated")
}

@(test)
test_animator_tail_weight_zero_keeps_state :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  idx := add_tail_layer(&a, &rig, "root", 4)
  world := linalg.MATRIX4F32_IDENTITY
  for _ in 0 ..< 60 do animator_update(&a, &rig, 1.0 / 60, world)
  // Hold the layer at weight 0 while the body moves away, then settle.
  set_layer_weight(&a, idx, 0)
  world = linalg.matrix4_translate_f32({20, 0, 0})
  for _ in 0 ..< 120 do animator_update(&a, &rig, 1.0 / 60, world)
  testing.expectf(t, almost_equal_vec3(a.positions[3], {0, 3, 0}), "weight 0 leaves FK pose, got %v", a.positions[3])
  set_layer_weight(&a, idx, 1)
  animator_update(&a, &rig, 1.0 / 60, world)
  testing.expectf(t, linalg.distance(a.positions[3], [3]f32{0, 3, 0}) < 0.1, "no whip when re-enabled, tip %v", a.positions[3])
}
