package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import mu "vendor:microui"

root_nodes: [dynamic]world.NodeHandle
animation_time: f32 = 0
spider_root_node: world.NodeHandle
spider_mesh_node: world.NodeHandle
spider_leg_layer_index: int = -1
target_markers: [6]world.NodeHandle
ground_plane: world.NodeHandle

// Group A (legs 0, 2, 4) and Group B (legs 1, 3, 5) live-tweakables.
lift_frequency_default :: f32(1.5)

lift_height_a: mu.Real = 0.5
lift_height_b: mu.Real = 0.5
lift_duration_a: mu.Real = 0.6
lift_duration_b: mu.Real = 0.6
lift_frequency_shared: mu.Real = mu.Real(lift_frequency_default)
phase_offset_b: mu.Real = mu.Real(lift_frequency_default * 0.5)

body_amplitude: mu.Real = 8.0
body_speed: mu.Real = 0.05
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
    {0, 80, 120},
    {0, 0, 0},
  )
  spider_roots := mjolnir.load_gltf(engine, "assets/spider.glb")
  append(&root_nodes, ..spider_roots[:])

  for handle in spider_roots {
    spider_root_node = handle
    world.translate(&engine.world, handle, y = 5)
  }

  leg_configs := []struct {
    root_name:      string,
    tip_name:       string,
    initial_offset: [3]f32,
    time_offset:    f32,
  } {
    {"leg_front_r_0", "leg_front_r_5", {0, 0, 0}, 0.0},                                  // 0: group A
    {"leg_middle_r_0", "leg_middle_r_5", {0, 0, 0}, lift_frequency_default * 0.5},       // 1: group B
    {"leg_back_r_0", "leg_back_r_5", {0, 0, 0}, 0.0},                                    // 2: group A
    {"leg_front_l_0", "leg_front_l_5", {0, 0, 0}, lift_frequency_default * 0.5},         // 3: group B
    {"leg_middle_l_0", "leg_middle_l_5", {0, 0, 0}, 0.0},                                // 4: group A
    {"leg_back_l_0", "leg_back_l_5", {0, 0, 0}, lift_frequency_default * 0.5},           // 5: group B
  }

  for handle in spider_roots {
    root_node := world.node(&engine.world, handle) or_continue

    for child in root_node.children {
      child_node := world.node(&engine.world, child) or_continue
      mesh_attachment, has_mesh := &child_node.attachment.(world.MeshAttachment)
      if !has_mesh {
        continue
      }

      mesh := world.mesh(&engine.world, mesh_attachment.handle) or_continue
      skin, has_skin := mesh.skinning.?
      if !has_skin {
        continue
      }

      for i in 0 ..< 6 {
        root_bone_idx := -1
        tip_bone_idx := -1
        for bone, idx in skin.bones {
          if bone.name == leg_configs[i].root_name {
            root_bone_idx = idx
          }
          if bone.name == leg_configs[i].tip_name {
            tip_bone_idx = idx
          }
        }
        if root_bone_idx >= 0 && tip_bone_idx >= 0 {
          root_bind := linalg.matrix4_inverse(
            skin.bones[root_bone_idx].inverse_bind_matrix,
          )
          tip_bind := linalg.matrix4_inverse(
            skin.bones[tip_bone_idx].inverse_bind_matrix,
          )
          offset := tip_bind[3].xyz - root_bind[3].xyz
          leg_configs[i].initial_offset = offset
        }
      }

      leg_root_names := make([]string, 6)
      leg_chain_lengths := make([]u32, 6)
      spider_leg_configs := make([]anim.SpiderLegConfig, 6)
      leg_constraints := make([][]anim.IKBoneConstraint, 6)

      deg30 := f32(math.PI / 6.0)
      deg90 := f32(math.PI / 2.0)

      for i in 0 ..< 6 {
        leg_root_names[i] = leg_configs[i].root_name
        leg_chain_lengths[i] = 6
        in_group_a := slice.contains(GROUP_A[:], i)
        spider_leg_configs[i] = anim.SpiderLegConfig {
          initial_offset = leg_configs[i].initial_offset,
          lift_height    = f32(in_group_a ? lift_height_a : lift_height_b),
          lift_frequency = f32(lift_frequency_shared),
          lift_duration  = f32(in_group_a ? lift_duration_a : lift_duration_b),
          time_offset    = leg_configs[i].time_offset,
        }

        chain := make([]anim.IKBoneConstraint, 6)
        chain[0] = anim.IKBoneConstraint{max_angle = {deg30, deg90, deg30}}
        for j in 1 ..< 6 {
          chain[j] = anim.IKBoneConstraint{max_angle = {deg90, deg90, deg90}}
        }
        leg_constraints[i] = chain
      }

      if world.add_spider_leg_modifier_layer(
        &engine.world,
        child,
        leg_root_names,
        leg_chain_lengths,
        spider_leg_configs,
        weight = 1.0,
        layer_index = -1,
        constraints = leg_constraints,
      ) {
        spider_mesh_node = child
        spider_leg_layer_index = 0
        log.infof("Added spider leg modifiers for all 6 legs")
      }

      break
    }
  }

  sphere_mesh := world.get_builtin_mesh(&engine.world, .SPHERE)
  red_mat := world.get_builtin_material(&engine.world, .RED)
  for i in 0 ..< 6 {
    target_markers[i] =
      world.spawn(
        &engine.world,
        {0, 0, 0},
        attachment = world.MeshAttachment {
          handle = sphere_mesh,
          material = red_mat,
        },
      ) or_else {}
    world.scale(&engine.world, target_markers[i], 0.2)
  }

  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  gray_mat := world.get_builtin_material(&engine.world, .GRAY)
  ground_plane =
    world.spawn(
      &engine.world,
      {0, 0, 0},
      attachment = world.MeshAttachment {
        handle = cube_mesh,
        material = gray_mat,
      },
    ) or_else {}
  world.scale_xyz(&engine.world, ground_plane, 20, 0.2, 20)
  world.spawn_light_point(&engine.world, {-15, 15, 20}, {0.6, 0.7, 1.0, 1.5}, 40.0, false)
}

apply_group :: proc(
  engine: ^mjolnir.Engine,
  group: []int,
  lift_height: f32,
  lift_duration: f32,
  lift_frequency: f32,
  time_offset: f32,
) {
  for leg_index in group {
    world.set_spider_leg_modifier_params(
      &engine.world,
      spider_mesh_node,
      spider_leg_layer_index,
      leg_index,
      lift_height = lift_height,
      lift_frequency = lift_frequency,
      lift_duration = lift_duration,
      time_offset = time_offset,
    )
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if body_anim_enabled {
    animation_time += delta_time
  }
  body_x := f32(body_amplitude) * math.sin(animation_time * f32(body_speed) * 2 * math.PI)
  body_pos := [3]f32{body_x, 2, 0}
  if node := world.node(&engine.world, spider_root_node); node != nil {
    world.translate(&node.transform, body_pos.x, body_pos.y, body_pos.z)
  }

  if spider_leg_layer_index >= 0 {
    apply_group(
      engine,
      GROUP_A[:],
      f32(lift_height_a),
      f32(lift_duration_a),
      f32(lift_frequency_shared),
      0.0,
    )
    apply_group(
      engine,
      GROUP_B[:],
      f32(lift_height_b),
      f32(lift_duration_b),
      f32(lift_frequency_shared),
      f32(phase_offset_b),
    )
  }

  if root_node := world.node(&engine.world, spider_root_node);
     root_node != nil {
    for child in root_node.children {
      child_node := world.node(&engine.world, child) or_continue
      _, has_mesh := &child_node.attachment.(world.MeshAttachment)
      if !has_mesh {
        continue
      }
      for i in 0 ..< 6 {
        if target, ok := world.get_spider_leg_target(
          &engine.world,
          child,
          layer_index = 0,
          leg_index = i,
        ); ok {
          if marker_node := world.node(&engine.world, target_markers[i]);
             marker_node != nil {
            world.translate(&marker_node.transform, target.x, target.y, target.z)
          }
        }
      }
      break
    }
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Spider Legs", {500, 20, 340, 480}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)

    mu.label(ctx, "Body motion")
    mu.checkbox(ctx, "Animate body", &body_anim_enabled)
    mu.label(ctx, "Amplitude")
    mu.slider(ctx, &body_amplitude, 0.0, 30.0)
    mu.label(ctx, "Speed (Hz)")
    mu.slider(ctx, &body_speed, 0.0, 1.0)

    mu.label(ctx, "Shared lift frequency (period s)")
    mu.slider(ctx, &lift_frequency_shared, 0.1, 4.0)
    mu.label(ctx, "Group B phase offset (s)")
    mu.slider(ctx, &phase_offset_b, 0.0, 4.0)

    mu.label(ctx, "Group A (legs 0, 2, 4)")
    mu.label(ctx, "Lift height")
    mu.slider(ctx, &lift_height_a, 0.0, 5.0)
    mu.label(ctx, "Lift duration (s)")
    mu.slider(ctx, &lift_duration_a, 0.05, 2.0)

    mu.label(ctx, "Group B (legs 1, 3, 5)")
    mu.label(ctx, "Lift height")
    mu.slider(ctx, &lift_height_b, 0.0, 5.0)
    mu.label(ctx, "Lift duration (s)")
    mu.slider(ctx, &lift_duration_b, 0.05, 2.0)
  }
}
