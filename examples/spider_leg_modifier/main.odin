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
body_pos_x: mu.Real = 0.0
body_pos_z: mu.Real = 0.0
body_lerp_rate: mu.Real = 2.0
body_max_speed: mu.Real = 4.0
body_current_pos: [3]f32 = {0, 2, 0}

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

  leg_meta := [6]struct {
    root_name:   string,
    tip_name:    string,
    time_offset: f32,
  } {
    {"leg_front_r_0",  "leg_front_r_5",  0.0},                          // 0: group A
    {"leg_middle_r_0", "leg_middle_r_5", lift_frequency_default * 0.5}, // 1: group B
    {"leg_back_r_0",   "leg_back_r_5",   0.0},                          // 2: group A
    {"leg_front_l_0",  "leg_front_l_5",  lift_frequency_default * 0.5}, // 3: group B
    {"leg_middle_l_0", "leg_middle_l_5", 0.0},                          // 4: group A
    {"leg_back_l_0",   "leg_back_l_5",   lift_frequency_default * 0.5}, // 5: group B
  }

  deg30 := f32(math.PI / 6.0)
  deg90 := f32(math.PI / 2.0)

  for handle in spider_roots {
    child, _, mesh_attachment, has_mesh := world.find_first_mesh_child(&engine.world, handle)
    if !has_mesh do continue
    mesh := world.mesh(&engine.world, mesh_attachment.handle) or_continue
    if _, has_skin := mesh.skinning.?; !has_skin do continue

    legs_spec := make([]world.SpiderLegSpec, 6)
    for i in 0 ..< 6 {
      offset, _ := world.bone_rest_offset(mesh, leg_meta[i].root_name, leg_meta[i].tip_name)
      in_group_a := slice.contains(GROUP_A[:], i)
      legs_spec[i] = world.SpiderLegSpec {
        root_name = leg_meta[i].root_name,
        chain_length = 6,
        config = anim.SpiderLegConfig {
          initial_offset = offset,
          lift_height    = f32(in_group_a ? lift_height_a : lift_height_b),
          lift_frequency = f32(lift_frequency_shared),
          lift_duration  = f32(in_group_a ? lift_duration_a : lift_duration_b),
          time_offset    = leg_meta[i].time_offset,
        },
        constraints = anim.ik_constraints_uniform(6, {deg30, deg90, deg30}, {deg90, deg90, deg90}),
      }
    }

    idx, ok := world.add_spider_leg_modifier_layer(&engine.world, child, legs_spec, weight = 1.0)
    if ok {
      spider_mesh_node = child
      spider_leg_layer_index = idx
      log.infof("Added spider leg modifiers for all 6 legs (layer %d)", spider_leg_layer_index)
    }
  }

  ground_plane = world.spawn_primitive_mesh(&engine.world, .CUBE, .GRAY)
  world.scale(&engine.world, ground_plane, [3]f32{20, 0.2, 20})
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
    body_x := f32(body_amplitude) * math.sin(animation_time * f32(body_speed) * 2 * math.PI)
    body_current_pos = {body_x, 2, 0}
    body_pos_x = mu.Real(body_x)
    body_pos_z = 0
  } else {
    target := [3]f32{f32(body_pos_x), 2, f32(body_pos_z)}
    t := 1 - math.exp(-f32(body_lerp_rate) * delta_time)
    desired := linalg.lerp(body_current_pos, target, t)
    step := desired - body_current_pos
    max_step := f32(body_max_speed) * delta_time
    step_len := linalg.length(step)
    if step_len > max_step {
      step *= max_step / step_len
    }
    body_current_pos += step
  }
  world.translate(&engine.world, spider_root_node, body_current_pos)

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

  red := [4]f32{1, 0.2, 0.2, 1}
  for i in 0 ..< 6 {
    target, ok := world.get_spider_leg_target(
      &engine.world,
      spider_mesh_node,
      layer_index = spider_leg_layer_index,
      leg_index = i,
    )
    if !ok do continue
    mjolnir.debug_sphere(engine, target^, 0.2, red)
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Spider Legs", {500, 20, 340, 480}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)

    mu.label(ctx, "Body motion")
    mu.checkbox(ctx, "Animate body", &body_anim_enabled)
    if body_anim_enabled {
      mu.label(ctx, "Amplitude")
      mu.slider(ctx, &body_amplitude, 0.0, 30.0)
      mu.label(ctx, "Speed (Hz)")
      mu.slider(ctx, &body_speed, 0.0, 1.0)
    } else {
      mu.label(ctx, "Body X")
      mu.slider(ctx, &body_pos_x, -30.0, 30.0)
      mu.label(ctx, "Body Z")
      mu.slider(ctx, &body_pos_z, -30.0, 30.0)
    }

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
