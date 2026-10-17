#+build !js
#+private
package animation

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:slice"
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
  testing.expect_value(t, clip_time(&a, 0), 1)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {10, 0, 0}))
  animator_update(&a, &rig, 1)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {10, 0, 0}), "holds last pose")
  testing.expect(t, almost_equal_vec3(model_pos(&a, 2), {10, 2, 0}))
  testing.expect(t, clip_seek(&a, 0, 0.25))
  animator_update(&a, &rig, 0.25)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {5, 0, 0}), "seek plays again")
}

@(test)
test_animator_ping_pong_keeps_speed :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  play(&a, &rig, "move", .PING_PONG)
  animator_update(&a, &rig, 1.25)
  testing.expect(t, abs(clip_time(&a, 0) - 0.75) < 1e-5, "reflected")
  p := layer_params(&a, 0, ClipParams)
  testing.expect_value(t, p.speed, 1) // turning around is state, not an input
  animator_update(&a, &rig, 0.25)
  testing.expect(t, abs(clip_time(&a, 0) - 0.5) < 1e-5, "still going back")
}

@(test)
test_animator_layer_weights_blend :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  l0 := layer_create(&a, &rig, ClipParams{clip = find_clip(&rig, "move"), speed = 1}, weight = 0.5)
  l1 := layer_create(&a, &rig, ClipParams{clip = find_clip(&rig, "up"), speed = 1}, weight = 0.5)
  testing.expect(t, l0 == 0 && l1 == 1)
  _, ok := layer_create(&a, &rig, ClipParams{clip = 9})
  testing.expect(t, !ok, "unknown clip")
  animator_update(&a, &rig, 0.5)
  testing.expectf(t, almost_equal_vec3(model_pos(&a, 0), {2.5, 2, 0}), "50/50 blend, got %v", model_pos(&a, 0))
  testing.expect(t, layer_fade(&a, 1, 0))
  testing.expect(t, !layer_fade(&a, 5, 0))
  animator_update(&a, &rig, 0.25)
  testing.expectf(t, almost_equal_vec3(model_pos(&a, 0), {7.5, 0, 0}), "only move, got %v", model_pos(&a, 0))
  // switch the clip of layer 0 in place
  layer_params(&a, 0, ClipParams).clip = find_clip(&rig, "up")
  animator_update(&a, &rig, 0)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {0, 4, 0}))
}

@(test)
test_animator_layer_mask :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  layer_create(&a, &rig, ClipParams{clip = find_clip(&rig, "wave"), speed = 1}, bones = []u32{find_bone(&rig.skeleton, "tip")})
  _, bad := layer_create(&a, &rig, ClipParams{clip = 0}, bones = []u32{9})
  testing.expect(t, !bad, "bone out of range")
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
test_animator_cross_fade :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  play(&a, &rig, "up")
  to := layer_create(&a, &rig, ClipParams{clip = find_clip(&rig, "move"), speed = 1}, weight = 0)
  testing.expect(t, layer_fade(&a, 0, 0, 0.5) && layer_fade(&a, to, 1, 0.5))
  animator_update(&a, &rig, 0.25)
  testing.expect(t, abs(layer_weight(&a, 0) - 0.5) < 1e-5 && abs(layer_weight(&a, to) - 0.5) < 1e-5)
  testing.expectf(t, almost_equal_vec3(model_pos(&a, 0), {1.25, 2, 0}), "mid fade, got %v", model_pos(&a, 0))
  animator_update(&a, &rig, 0.3)
  testing.expect(t, layer_weight(&a, 0) == 0 && layer_weight(&a, to) == 1)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {5.5, 0, 0}), "only target clip")
  testing.expect_value(t, layer_weight(&a, 7), 0)
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
  idx, ok := layer_create(&a, &rig, IKParams{target = target, pole = {1, 0, 0}, pole_weight = 1}, bone_chain(&rig.skeleton, "root", "tip", context.temp_allocator))
  testing.expect(t, ok && idx == 0)
  _, bad := layer_create(&a, &rig, IKParams{target = target}, []u32{2, 1, 0})
  testing.expect(t, !bad, "inverted chain rejected")
  _, bad2 := layer_create(&a, &rig, IKParams{target = target}, []u32{0})
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
  // weight 0 -> back to rest
  testing.expect(t, layer_fade(&a, 0, 0))
  animator_update(&a, &rig, 0.016)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 2), {0, 2, 0}))
  layer_fade(&a, 0, 1)
  layer_params(&a, 0, IKParams).target = {-1, 1, 0}
  testing.expect(t, layer_params(&a, 0, TailParams) == nil, "wrong kind")
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
  chain := bone_chain(&rig.skeleton, "root", "tip", context.temp_allocator)
  layer_create(&local, &rig, IKParams{target = {1, 1, 0}, pole = {1, 0, 0}, pole_weight = 1}, chain)
  layer_create(&world, &rig, IKParams{target = [3]f32{1, 1, 0} + offset, pole = [3]f32{1, 0, 0} + offset, pole_weight = 1, space = .WORLD}, chain)
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
  layer_create(&a, &rig, IKParams{target = {6, 1, 0}}, bone_chain(&rig.skeleton, "root", "tip", context.temp_allocator))
  animator_update(&a, &rig, 0.5)
  testing.expect(t, almost_equal_vec3(model_pos(&a, 0), {5, 0, 0}), "FK root")
  testing.expect(t, linalg.distance(model_pos(&a, 2), [3]f32{6, 1, 0}) < 0.01, "IK on top of FK")
}

@(test)
test_animator_destroy_and_clear_layers :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  layer_create(&a, &rig, ClipParams{clip = 0, speed = 1})
  layer_create(&a, &rig, IKParams{target = {1, 1, 0}}, []u32{0, 1, 2})
  tail := layer_create(&a, &rig, TailParams{stiffness = 0.5, damping = 0.9}, []u32{1, 2, 3})
  testing.expect_value(t, len(a.layers), 3)
  testing.expect(t, layer_destroy(&a, 1))
  testing.expect(t, !layer_destroy(&a, 7))
  testing.expect(t, !layer_destroy(&a, 1), "destroyed slot is empty")
  testing.expect(t, !layer_fade(&a, 1, 0.5), "destroyed slot is invalid")
  testing.expect_value(t, len(a.layers), 3)
  testing.expect(t, layer_params(&a, tail, TailParams) != nil, "later layers keep their handle")
  // the pools close the gap: the tail's bones follow the clip's (none)
  testing.expect_value(t, len(a.bones), 3)
  testing.expect(t, slice.equal(a.bones[a.layers[tail].bones.start:][:3], []u32{1, 2, 3}))
  testing.expect_value(t, layer_create(&a, &rig, ClipParams{clip = 1, speed = 1}), 1) // freed slot is reused
  testing.expect_value(t, len(a.layers), 3)
  clear_layers(&a)
  testing.expect_value(t, len(a.layers), 0)
  testing.expect_value(t, len(a.state), 0)
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
    layer_create(&a, &rig, IKParams{target = {1, 1, 0}}, []u32{0, 1, 2})
    layer_create(&a, &rig, TailParams{stiffness = 0.5}, []u32{1, 2, 3})
    path := layer_create(&a, &rig, PathParams{}, []u32{0, 1, 2})
    path_points(&a, path, {{0, 0, 0}, {0, 1, 0}, {1, 2, 0}})
    path_points(&a, path, {{0, 0, 0}, {0, 1, 0}, {1, 2, 0}, {2, 2, 0}}, closed = true)
    layer_destroy(&a, 1)
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
  idx, ok := layer_create(&a, &rig, TailParams{stiffness = 0.5, damping = 0.9}, []u32{1, 2, 3})
  testing.expect(t, ok && idx == 1)
  _, bad := layer_create(&a, &rig, TailParams{}, []u32{3})
  testing.expect(t, !bad, "one bone is no chain")
  layer_params(&a, idx, TailParams).damping = 0.8
  testing.expect(t, layer_params(&a, 0, TailParams) == nil, "not a tail layer")
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
test_animator_ik_layer_weight_blends :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  idx := layer_create(&a, &rig, IKParams{target = {1.5, 0.5, 0}}, []u32{0, 1, 2})
  animator_update(&a, &rig, 0.016)
  full := a.positions[2]
  layer_fade(&a, idx, 0.5)
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
  idx := layer_create(&a, &rig, TailParams{stiffness = 0.5, damping = 0.9}, []u32{0, 1, 2, 3})
  world := linalg.MATRIX4F32_IDENTITY
  for _ in 0 ..< 60 do animator_update(&a, &rig, 1.0 / 60, world)
  // Hold the layer at weight 0 while the body moves away, then settle.
  layer_fade(&a, idx, 0)
  world = linalg.matrix4_translate_f32({20, 0, 0})
  for _ in 0 ..< 120 do animator_update(&a, &rig, 1.0 / 60, world)
  testing.expectf(t, almost_equal_vec3(a.positions[3], {0, 3, 0}), "weight 0 leaves FK pose, got %v", a.positions[3])
  layer_fade(&a, idx, 1)
  animator_update(&a, &rig, 1.0 / 60, world)
  testing.expectf(t, linalg.distance(a.positions[3], [3]f32{0, 3, 0}) < 0.1, "no whip when re-enabled, tip %v", a.positions[3])
}

// Moves its bone to (9, 9, 9).
@(private = "file")
pin :: proc(pose: Pose, bones: []u32, state: []f32, values: [8]f32, dt: f32, fresh: bool) {
  pose.positions[bones[0]] = {9, 9, 9}
}

// Pose-editing layers run by priority: whichever of a custom layer and an IK layer on the
// same bone runs last decides where it ends up.
@(test)
test_animator_priority_orders_layers :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  pose_after :: proc(rig: ^Rig, custom_priority: i32) -> [3]f32 {
    a: Animator
    animator_init(&a, rig)
    defer animator_destroy(&a)
    layer_create(&a, rig, IKParams{target = {1.5, 0.5, 0}}, []u32{0, 1, 2})
    layer_create(&a, rig, CustomParams{apply = pin}, []u32{2}, priority = custom_priority)
    animator_update(&a, rig, 0.016)
    return a.positions[2]
  }
  testing.expect(t, almost_equal_vec3(pose_after(&rig, 300), {9, 9, 9}), "custom after IK wins")
  testing.expect(t, linalg.distance(pose_after(&rig, 100), [3]f32{1.5, 0.5, 0}) < 0.01, "IK after custom wins")
}

// A custom layer keeps its own state and is blended by its weight like a built-in.
@(test)
test_animator_custom_layer :: proc(t: ^testing.T) {
  rig: Rig
  testing.expect(t, make_test_rig(&rig))
  defer rig_destroy(&rig)
  a: Animator
  animator_init(&a, &rig)
  defer animator_destroy(&a)
  // lifts the bone by values[0] per update, counting updates in its state
  lift :: proc(pose: Pose, bones: []u32, state: []f32, values: [8]f32, dt: f32, fresh: bool) {
    if fresh do state[0] = 0
    state[0] += 1
    pose.positions[bones[0]].y += values[0] * state[0]
  }
  h := layer_create(&a, &rig, CustomParams{apply = lift, values = {1, 0, 0, 0, 0, 0, 0, 0}, state = 1}, []u32{3}, weight = 0.5)
  animator_update(&a, &rig, 0.016)
  testing.expect(t, almost_equal_vec3(a.positions[3], {0, 3.5, 0}), "half of +1")
  animator_update(&a, &rig, 0.016)
  testing.expect(t, almost_equal_vec3(a.positions[3], {0, 4, 0}), "half of +2: state kept")
  layer_params(&a, h, CustomParams).values[0] = 2
  animator_update(&a, &rig, 0.016)
  testing.expect(t, almost_equal_vec3(a.positions[3], {0, 6, 0}), "half of +6")
}
