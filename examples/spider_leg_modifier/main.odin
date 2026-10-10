package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"
import mu "vendor:microui"

scene: mjolnir.GltfScene
rig: ^animation.Rig
animator: animation.Animator
animation_time: f32 = 0
spider_root_node: world.NodeHandle
spider_mesh_node: world.NodeHandle
spider_leg_layer_index: int = -1
ground_plane: world.NodeHandle

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
  defer mjolnir.gltf_scene_destroy(&scene)
  mjolnir.run_app({
    title      = "Spider Leg",
    width      = 900,
    height     = 700,
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  render.main_camera_look_at(&engine.render, {0, 30, 15}, {0, 0, 0})
  scene = mjolnir.load_gltf(engine, "assets/spider.glb")
  if len(scene.roots) == 0 || len(scene.skinned) == 0 do return
  spider_root_node = scene.roots[0]
  world.translate(&engine.world, spider_root_node, y = 5)
  spider_mesh_node = scene.skinned[0].node
  rig = &scene.rigs[scene.skinned[0].rig]
  skel := &rig.skeleton
  animation.animator_init(&animator, rig)

  leg_meta := [6]struct{root_name, tip_name: string, time_offset: f32}{
    {"leg_front_r_0",  "leg_front_r_5",  0.0},
    {"leg_middle_r_0", "leg_middle_r_5", lift_frequency_default * 0.5},
    {"leg_back_r_0",   "leg_back_r_5",   0.0},
    {"leg_front_l_0",  "leg_front_l_5",  lift_frequency_default * 0.5},
    {"leg_middle_l_0", "leg_middle_l_5", 0.0},
    {"leg_back_l_0",   "leg_back_l_5",   lift_frequency_default * 0.5},
  }

  deg30 := f32(math.PI / 6.0)
  deg90 := f32(math.PI / 2.0)
  legs: [6]animation.SpiderLegConfig
  for &leg, i in legs {
    offset, _ := animation.rest_offset(skel, leg_meta[i].root_name, leg_meta[i].tip_name)
    in_group_a := slice.contains(GROUP_A[:], i)
    leg = {
      root           = leg_meta[i].root_name,
      chain_length   = 6,
      constraints    = animation.ik_constraints_uniform(6, {deg30, deg90, deg30}, {deg90, deg90, deg90}),
      offset         = offset,
      lift_height    = f32(in_group_a ? lift_height_a : lift_height_b),
      lift_frequency = f32(lift_frequency_shared),
      lift_duration  = f32(in_group_a ? lift_duration_a : lift_duration_b),
      time_offset    = leg_meta[i].time_offset,
    }
  }
  if idx, ok := animation.add_spider_leg_layer(&animator, rig, legs[:], weight = 1.0); ok {
    spider_leg_layer_index = idx
    log.infof("Added spider leg modifiers for all 6 legs (layer %d)", spider_leg_layer_index)
  }

  ground_plane = mjolnir.spawn_primitive_mesh(engine, .CUBE, .GRAY)
  world.scale(&engine.world, ground_plane, [3]f32{20, 0.2, 20})
  mjolnir.spawn(engine, {-15, 15, 20}, render.point_light_attachment({0.6, 0.7, 1.0, 1.5}, 40.0, false))
}

apply_group :: proc(engine: ^mjolnir.Engine, group: []int, lift_height, lift_duration, lift_frequency, time_offset: f32) {
  for leg_index in group {
    animation.set_spider_leg_params(&animator, spider_leg_layer_index, leg_index,
      lift_height = lift_height, lift_frequency = lift_frequency,
      lift_duration = lift_duration, time_offset = time_offset,
    )
  }
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if body_anim_enabled {
    animation_time += dt
    body_x := f32(body_amplitude) * math.sin(animation_time * f32(body_speed) * 2 * math.PI)
    body_current_pos = {body_x, 2, 0}
    body_pos_x = mu.Real(body_x)
    body_pos_z = 0
  } else {
    target := [3]f32{f32(body_pos_x), 2, f32(body_pos_z)}
    t := 1 - math.exp(-f32(body_lerp_rate) * dt)
    desired := linalg.lerp(body_current_pos, target, t)
    step := desired - body_current_pos
    max_step := f32(body_max_speed) * dt
    step_len := linalg.length(step)
    if step_len > max_step do step *= max_step / step_len
    body_current_pos += step
  }
  world.translate(&engine.world, spider_root_node, body_current_pos)

  if spider_leg_layer_index >= 0 {
    apply_group(engine, GROUP_A[:], f32(lift_height_a), f32(lift_duration_a), f32(lift_frequency_shared), 0.0)
    apply_group(engine, GROUP_B[:], f32(lift_height_b), f32(lift_duration_b), f32(lift_frequency_shared), f32(phase_offset_b))
  }

  if rig != nil do animation.animator_update(&animator, rig, dt, world.world_matrix(&engine.world, spider_mesh_node))

  red := [4]f32{1, 0.2, 0.2, 1}
  for i in 0 ..< 6 {
    target, ok := animation.spider_leg_target(&animator, spider_leg_layer_index, i)
    if !ok do continue
    render.debug_sphere(&engine.render, target^, 0.2, red)
  }
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
  if rig != nil do render.stage_bones(&engine.render, spider_mesh_node.index, animator.palette)
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := render.debug_ui(&engine.render)
  if mu.window(ctx, "Spider Legs", {500, 20, 340, 480}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Body motion")
    mu.checkbox(ctx, "Animate body", &body_anim_enabled)
    if body_anim_enabled {
      mu.label(ctx, "Amplitude"); mu.slider(ctx, &body_amplitude, 0.0, 30.0)
      mu.label(ctx, "Speed (Hz)"); mu.slider(ctx, &body_speed, 0.0, 1.0)
    } else {
      mu.label(ctx, "Body X"); mu.slider(ctx, &body_pos_x, -30.0, 30.0)
      mu.label(ctx, "Body Z"); mu.slider(ctx, &body_pos_z, -30.0, 30.0)
    }
    mu.label(ctx, "Shared lift frequency (period s)"); mu.slider(ctx, &lift_frequency_shared, 0.1, 4.0)
    mu.label(ctx, "Group B phase offset (s)"); mu.slider(ctx, &phase_offset_b, 0.0, 4.0)
    mu.label(ctx, "Group A (legs 0, 2, 4)")
    mu.label(ctx, "Lift height"); mu.slider(ctx, &lift_height_a, 0.0, 5.0)
    mu.label(ctx, "Lift duration (s)"); mu.slider(ctx, &lift_duration_a, 0.05, 2.0)
    mu.label(ctx, "Group B (legs 1, 3, 5)")
    mu.label(ctx, "Lift height"); mu.slider(ctx, &lift_height_b, 0.0, 5.0)
    mu.label(ctx, "Lift duration (s)"); mu.slider(ctx, &lift_duration_b, 0.05, 2.0)
  }
}
