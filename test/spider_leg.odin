package tests
import "../mjolnir/animation"
import "core:log"
import "core:math/linalg"
import "core:testing"

@(test)
test_spider_leg_grounded :: proc(t: ^testing.T) {
  leg: animation.SpiderLeg
  animation.spider_leg_init(&leg, {1, 0, 0})
  animation.spider_leg_update(&leg, 0.5)
  testing.expect_value(t, leg.feet_position, [3]f32{1, 0, 0})
}

@(test)
test_spider_leg_lift_at_cycle_start :: proc(t: ^testing.T) {
  leg: animation.SpiderLeg
  animation.spider_leg_init(&leg, {0, 0, 0})
  leg.feet_target = {1, 0, 0}
  animation.spider_leg_update(&leg, 0.1)
  testing.expect(t, leg.feet_position.y > 0, "Foot should be lifted")
  testing.expect(
    t,
    leg.feet_position.x > 0 && leg.feet_position.x < 1,
    "Foot should be moving horizontally",
  )
}

@(test)
test_spider_leg_parabolic_height :: proc(t: ^testing.T) {
  testing.expect_value(t, animation.compute_parabolic_height(0.0, 1.0), 0.0)
  testing.expect_value(t, animation.compute_parabolic_height(0.5, 1.0), 1.0)
  testing.expect_value(t, animation.compute_parabolic_height(1.0, 1.0), 0.0)
  testing.expect_value(t, animation.compute_parabolic_height(0.25, 1.0), 0.75)
  testing.expect_value(t, animation.compute_parabolic_height(0.75, 1.0), 0.75)
}

@(test)
test_spider_leg_landing :: proc(t: ^testing.T) {
  leg: animation.SpiderLeg
  animation.spider_leg_init(&leg, {0, 0, 0})
  leg.feet_target = {1, 0, 0}
  animation.spider_leg_update(&leg, 0.2)
  testing.expect(t, leg.feet_position.y > 0, "Foot should be in air")
  animation.spider_leg_update(&leg, 0.3)
  testing.expect_value(t, leg.feet_position, [3]f32{1, 0, 0})
  testing.expect_value(t, leg.feet_last_target, [3]f32{1, 0, 0})
}

@(test)
test_spider_leg_time_offset :: proc(t: ^testing.T) {
  leg1, leg2: animation.SpiderLeg
  animation.spider_leg_init(&leg1, {0, 0, 0}, time_offset = 0.0)
  animation.spider_leg_init(&leg2, {0, 0, 0}, time_offset = 1.0)
  leg1.feet_target = {1, 0, 0}
  leg2.feet_target = {1, 0, 0}
  animation.spider_leg_update(&leg1, 0.1)
  animation.spider_leg_update(&leg2, 0.1)
  testing.expect(t, leg1.feet_position.y > 0, "Leg1 should be lifting")
  testing.expect_value(t, leg2.feet_position.y, 0.0)
}

@(test)
test_spider_leg_retarget_mid_flight :: proc(t: ^testing.T) {
  leg: animation.SpiderLeg
  animation.spider_leg_init(&leg, {0, 0, 0})
  leg.feet_target = {1, 0, 0}
  animation.spider_leg_update(&leg, 0.2)
  mid_pos := leg.feet_position
  leg.feet_target = {2, 0, 0}
  animation.spider_leg_update(&leg, 0.1)
  testing.expect(
    t,
    leg.feet_position.x > mid_pos.x,
    "Should retarget toward new position",
  )
}

@(test)
test_spider_leg_zero_duration :: proc(t: ^testing.T) {
  leg: animation.SpiderLeg
  animation.spider_leg_init(&leg, {0, 0, 0}, lift_duration = 0.0)
  leg.feet_target = {1, 0, 0}
  animation.spider_leg_update(&leg, 0.1)
  testing.expect_value(t, leg.feet_position, [3]f32{1, 0, 0})
  testing.expect_value(t, leg.feet_position.y, 0.0)
}

@(test)
test_spider_leg_full_cycle :: proc(t: ^testing.T) {
  leg: animation.SpiderLeg
  animation.spider_leg_init(&leg, {0, 0, 0})
  leg.feet_target = {1, 0, 0}
  animation.spider_leg_update(&leg, 0.2)
  testing.expect(t, leg.feet_position.y > 0, "Should be lifting")
  animation.spider_leg_update(&leg, 0.3)
  testing.expect_value(t, leg.feet_position.y, 0.0)
  testing.expect_value(t, leg.feet_position, [3]f32{1, 0, 0})
  animation.spider_leg_update(&leg, 1.5)
  testing.expect_value(t, leg.feet_position, [3]f32{1, 0, 0})
  animation.spider_leg_update(&leg, 0.2)
  testing.expect(t, leg.feet_position.y > 0, "Should lift again in next cycle")
}

@(test)
test_spider_leg_modifier_single_leg :: proc(t: ^testing.T) {
  state := animation.ProceduralState {
    bone_indices     = []u32{0, 1, 2},
    accumulated_time = 0,
    modifier         = animation.SpiderLegModifier {
      legs          = make([]animation.SpiderLeg, 1),
      chain_starts  = []u32{0},
      chain_lengths = []u32{3},
    },
  }
  defer {
    modifier := &state.modifier.(animation.SpiderLegModifier)
    delete(modifier.legs)
  }

  modifier := &state.modifier.(animation.SpiderLegModifier)
  animation.spider_leg_init(&modifier.legs[0], {0, 0, 0})
  modifier.legs[0].feet_target = {1, 0, 0}

  transforms := make([]animation.BoneTransform, 10)
  defer delete(transforms)
  for i in 0 ..< len(transforms) {
    transforms[i].world_position = {f32(i), 0, 0}
    transforms[i].world_rotation = linalg.QUATERNIONF32_IDENTITY
    transforms[i].world_matrix = linalg.MATRIX4F32_IDENTITY
  }

  bone_lengths := make([]f32, 10)
  defer delete(bone_lengths)
  for i in 0 ..< len(bone_lengths) {
    bone_lengths[i] = 1.0
  }

  animation.spider_leg_modifier_update(
    &state,
    modifier,
    0.1,
    transforms[:],
    1.0,
    bone_lengths[:],
  )

  testing.expect(
    t,
    modifier.legs[0].feet_position.y > 0,
    "Foot should be lifted in first update",
  )
}

@(test)
test_spider_leg_modifier_multiple_legs :: proc(t: ^testing.T) {
  state := animation.ProceduralState {
    bone_indices     = []u32{0, 1, 2, 3, 4, 5},
    accumulated_time = 0,
    modifier         = animation.SpiderLegModifier {
      legs          = make([]animation.SpiderLeg, 2),
      chain_starts  = []u32{0, 3},
      chain_lengths = []u32{3, 3},
    },
  }
  defer {
    modifier := &state.modifier.(animation.SpiderLegModifier)
    delete(modifier.legs)
  }

  modifier := &state.modifier.(animation.SpiderLegModifier)
  animation.spider_leg_init(&modifier.legs[0], {0, 0, 0}, time_offset = 0.0)
  animation.spider_leg_init(&modifier.legs[1], {0, 0, 1}, time_offset = 0.5)
  modifier.legs[0].feet_target = {1, 0, 0}
  modifier.legs[1].feet_target = {1, 0, 1}

  transforms := make([]animation.BoneTransform, 10)
  defer delete(transforms)
  for i in 0 ..< len(transforms) {
    transforms[i].world_position = {f32(i), 0, 0}
    transforms[i].world_rotation = linalg.QUATERNIONF32_IDENTITY
    transforms[i].world_matrix = linalg.MATRIX4F32_IDENTITY
  }

  bone_lengths := make([]f32, 10)
  defer delete(bone_lengths)
  for i in 0 ..< len(bone_lengths) {
    bone_lengths[i] = 1.0
  }

  animation.spider_leg_modifier_update(
    &state,
    modifier,
    0.1,
    transforms[:],
    1.0,
    bone_lengths[:],
  )

  testing.expect(
    t,
    modifier.legs[0].feet_position.y > 0,
    "Leg 0 should be lifting",
  )
  testing.expect_value(t, modifier.legs[1].feet_position.y, 0.0)
}

@(test)
test_spider_leg_modifier_invalid_chain :: proc(t: ^testing.T) {
  state := animation.ProceduralState {
    bone_indices     = []u32{0},
    accumulated_time = 0,
    modifier         = animation.SpiderLegModifier {
      legs          = make([]animation.SpiderLeg, 1),
      chain_starts  = []u32{0},
      chain_lengths = []u32{1},
    },
  }
  defer {
    modifier := &state.modifier.(animation.SpiderLegModifier)
    delete(modifier.legs)
  }

  modifier := &state.modifier.(animation.SpiderLegModifier)
  animation.spider_leg_init(&modifier.legs[0], {0, 0, 0})

  transforms := make([]animation.BoneTransform, 10)
  defer delete(transforms)

  bone_lengths := make([]f32, 10)
  defer delete(bone_lengths)

  animation.spider_leg_modifier_update(
    &state,
    modifier,
    0.1,
    transforms[:],
    1.0,
    bone_lengths[:],
  )
}
