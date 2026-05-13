package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import mu "vendor:microui"

leg_root_node: world.NodeHandle
target_markers: [6]world.NodeHandle
feet_markers: [6]world.NodeHandle
ground_plane_node: world.NodeHandle

spider_legs: [6]anim.SpiderLeg
animation_time: f32 = 0

// Group A = legs 0,2,4,6; Group B = legs 1,3,5,7.
lift_frequency_default :: f32(2.0)

lift_height_a: mu.Real = 4.0
lift_height_b: mu.Real = 4.0
lift_duration_a: mu.Real = 0.5
lift_duration_b: mu.Real = 0.5
lift_frequency_shared: mu.Real = mu.Real(lift_frequency_default)
phase_offset_b: mu.Real = mu.Real(lift_frequency_default * 0.5)

body_amplitude: mu.Real = 30.0
body_speed: mu.Real = 0.1
body_anim_enabled: bool = true

GROUP_A := [3]int{0, 2, 4}
GROUP_B := [3]int{1, 3, 5}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 900, 700, "Spider Leg")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(
    &engine.world,
    {0, 50, 100},
    {0, 0, 0},
  )

  // Walk circle clockwise (viewed from +Y). Body along X, sides along Z.
  leg_offsets := [6][3]f32 {
    { 4, -10,  12}, // 0: front right
    { 0, -10,  14}, // 1: mid right
    {-4, -10,  12}, // 2: back right
    {-4, -10, -12}, // 3: back left
    { 0, -10, -14}, // 4: mid left
    { 4, -10, -12}, // 5: front left
  }

  for i in 0 ..< 6 {
    in_group_a := i % 2 == 0
    anim.spider_leg_init(
      &spider_legs[i],
      initial_offset = leg_offsets[i],
      lift_height = f32(in_group_a ? lift_height_a : lift_height_b),
      lift_frequency = f32(lift_frequency_shared),
      lift_duration = f32(in_group_a ? lift_duration_a : lift_duration_b),
      time_offset = in_group_a ? 0.0 : f32(phase_offset_b),
    )
  }

  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)

  blue_mat := world.get_builtin_material(&engine.world, .BLUE)
  leg_root_node =
    world.spawn(
      &engine.world,
      {0, 10, 0},
      world.MeshAttachment{handle = cube_mesh, material = blue_mat},
    ) or_else {}
  world.scale(&engine.world, leg_root_node, 2.0)

  yellow_mat := world.get_builtin_material(&engine.world, .YELLOW)
  green_mat := world.get_builtin_material(&engine.world, .GREEN)

  for i in 0 ..< 6 {
    target_markers[i] =
      world.spawn(
        &engine.world,
        {0, 0, 0},
        world.MeshAttachment{handle = cube_mesh, material = yellow_mat},
      ) or_else {}
    world.scale(&engine.world, target_markers[i], 0.3)

    feet_markers[i] =
      world.spawn(
        &engine.world,
        {0, 0, 0},
        world.MeshAttachment{handle = sphere_mesh, material = green_mat},
      ) or_else {}
    world.scale(&engine.world, feet_markers[i], 0.8)
  }

  gray_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground_plane_node =
    world.spawn(
      &engine.world,
      {0, 0, 0},
      attachment = world.MeshAttachment {
        handle = cube_mesh,
        material = gray_mat,
      },
    ) or_else {}
  world.scale_xyz(&engine.world, ground_plane_node, 100, 0.2, 100)
  world.spawn_light_point(&engine.world, {0, 10, 10}, {1.0, 0.9, 0.8, 1.0}, 30.0, true)
}

apply_group_params :: proc(
  group: []int,
  lift_height: f32,
  lift_duration: f32,
  lift_frequency: f32,
  time_offset: f32,
) {
  for leg_index in group {
    leg := &spider_legs[leg_index]
    leg.feet_lift_height = lift_height
    leg.feet_lift_frequency = lift_frequency
    leg.feet_lift_duration = lift_duration
    leg.feet_lift_time_offset = time_offset
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if body_anim_enabled {
    animation_time += delta_time
  }
  root_x := f32(body_amplitude) * math.sin(animation_time * f32(body_speed) * 2 * math.PI)
  root_pos := [3]f32{root_x, 10, 0}

  if node := world.node(&engine.world, leg_root_node); node != nil {
    world.translate(&node.transform, root_pos.x, root_pos.y, root_pos.z)
  }

  apply_group_params(
    GROUP_A[:],
    f32(lift_height_a),
    f32(lift_duration_a),
    f32(lift_frequency_shared),
    0.0,
  )
  apply_group_params(
    GROUP_B[:],
    f32(lift_height_b),
    f32(lift_duration_b),
    f32(lift_frequency_shared),
    f32(phase_offset_b),
  )

  for i in 0 ..< 6 {
    anim.spider_leg_update_with_root(&spider_legs[i], delta_time, root_pos)

    if node := world.node(&engine.world, target_markers[i]); node != nil {
      tgt := spider_legs[i].feet_target
      world.translate(&node.transform, tgt.x, tgt.y, tgt.z)
    }
    if node := world.node(&engine.world, feet_markers[i]); node != nil {
      fp := spider_legs[i].feet_position
      world.translate(&node.transform, fp.x, fp.y, fp.z)
    }
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Spider Legs", {20, 20, 340, 480}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)

    mu.label(ctx, "Body motion")
    mu.checkbox(ctx, "Animate body", &body_anim_enabled)
    mu.label(ctx, "Amplitude")
    mu.slider(ctx, &body_amplitude, 0.0, 80.0)
    mu.label(ctx, "Speed (Hz)")
    mu.slider(ctx, &body_speed, 0.0, 1.0)

    mu.label(ctx, "Shared lift frequency (period s)")
    mu.slider(ctx, &lift_frequency_shared, 0.1, 4.0)
    mu.label(ctx, "Group B phase offset (s)")
    mu.slider(ctx, &phase_offset_b, 0.0, 4.0)

    mu.label(ctx, "Group A (legs 0, 2, 4)")
    mu.label(ctx, "Lift height")
    mu.slider(ctx, &lift_height_a, 0.0, 10.0)
    mu.label(ctx, "Lift duration (s)")
    mu.slider(ctx, &lift_duration_a, 0.05, 2.0)

    mu.label(ctx, "Group B (legs 1, 3, 5)")
    mu.label(ctx, "Lift height")
    mu.slider(ctx, &lift_height_b, 0.0, 10.0)
    mu.label(ctx, "Lift duration (s)")
    mu.slider(ctx, &lift_duration_b, 0.05, 2.0)
  }
}
