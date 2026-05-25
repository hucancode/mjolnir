package main

import "../../mjolnir"
import "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:fmt"
import "core:log"
import "core:math"
import mu "vendor:microui"

root_nodes: [dynamic]world.NodeHandle
animation_time: f32 = 0
spider_root_node: world.NodeHandle
mesh_node: world.NodeHandle
ground_plane: world.NodeHandle

leg_targets: [6][3]f32
leg_layers: [6]int = {-1, -1, -1, -1, -1, -1}

body_amplitude: mu.Real = 2.5
body_speed: mu.Real = 0.15
leg_lift: mu.Real = 2.5
ik_weight: mu.Real = 1.0
paused: bool = false
show_markers: bool = true
manual_feet: bool = false
foot_y: [6]mu.Real = {0, 0, 0, 0, 0, 0}

LEG_NAMES := [6]string{"FR", "MR", "BR", "FL", "ML", "BL"}

main :: proc() {
  mjolnir.run_app({
    title      = "IK",
    debug_ui   = true,
    setup      = setup,
    update     = update,
    pre_render = debug_ui,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {0, 20, 20}, {0, 0, 0})

  spider_roots := mjolnir.load_gltf(engine, "assets/spider.glb")
  append(&root_nodes, ..spider_roots[:])
  if len(spider_roots) == 0 do return
  spider_root_node = spider_roots[0]
  world.translate(&engine.world, spider_root_node, [3]f32{0, 5, 0})
  child, has := world.skinned_mesh_child(&engine.world, spider_root_node)
  if !has do return
  mesh_node = child

  leg_configs := []struct{root_name, tip_name: string}{
    {"leg_front_r_0", "leg_front_r_5"},
    {"leg_middle_r_0", "leg_middle_r_5"},
    {"leg_back_r_0", "leg_back_r_5"},
    {"leg_front_l_0", "leg_front_l_5"},
    {"leg_middle_l_0", "leg_middle_l_5"},
    {"leg_back_l_0", "leg_back_l_5"},
  }

  body_pos := [3]f32{0, 5, 0}
  deg30 := f32(math.PI / 6.0)
  deg90 := f32(math.PI / 2.0)

  for i in 0 ..< 6 {
    tip_local, has_tip := world.bone_rest_position(&engine.world, child, leg_configs[i].tip_name)
    if !has_tip {
      log.warnf("Leg %d: tip %s missing", i, leg_configs[i].tip_name)
      continue
    }
    leg_targets[i] = {tip_local.x + body_pos.x, 0, tip_local.z + body_pos.z}

    pole_pos := [3]f32{0, 10, 0}
    if root_local, has_root := world.bone_rest_position(&engine.world, child, leg_configs[i].root_name); has_root {
      root_world := root_local + body_pos
      pole_pos = {root_world.x * 0.5, root_world.y + 10, root_world.z * 0.5}
    }

    constraints := animation.ik_constraints_uniform(6, {deg30, deg90, deg30}, {deg90, deg90, deg90})

    idx, err := world.add_ik_layer_chain(&engine.world, child, leg_configs[i].root_name, leg_configs[i].tip_name,
      leg_targets[i], pole_pos, weight = 1.0, constraints = constraints, space = .WORLD,
    )
    if err != .NONE {
      log.errorf("IK layer add failed leg %d: %v", i, err)
    } else {
      leg_layers[i] = idx
    }
  }

  ground_plane = world.spawn_primitive_mesh(&engine.world, .CUBE, .GRAY)
  world.scale(&engine.world, ground_plane, [3]f32{40, 0.2, 40})
  world.spawn_light_directional(&engine.world, color = {1, 1, 1, 1}, radius = 10.0)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if !paused do animation_time += dt
  amp := f32(body_amplitude)
  spd := f32(body_speed)
  lift := f32(leg_lift)

  body_x := amp * math.sin(animation_time * spd * 2 * math.PI)
  body_pos := [3]f32{body_x, 0, 0}
  world.translate(&engine.world, spider_root_node, body_pos)

  for i in 0 ..< 6 {
    pole_pos := [3]f32{leg_targets[i].x * 0.5 + body_pos.x * 0.5, 5, leg_targets[i].z * 0.5}
    target_pos := leg_targets[i]
    if manual_feet {
      target_pos.y += f32(foot_y[i])
    } else {
      target_pos.y += lift * math.max(math.sin(animation_time * spd * math.PI), 0)
    }
    if leg_layers[i] >= 0 {
      world.set_ik_layer_target(&engine.world, mesh_node, leg_layers[i], target_pos, pole_pos)
      world.set_animation_layer_weight(&engine.world, mesh_node, leg_layers[i], f32(ik_weight))
    }
    if show_markers {
      mjolnir.debug_sphere(engine, target_pos, 0.5, {1, 0.2, 0.2, 1})
      mjolnir.debug_sphere(engine, pole_pos, 0.3, {0.3, 0.5, 1, 1})
    }
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "IK", {480, 20, 300, 560}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.checkbox(ctx, "Pause", &paused)
    mu.checkbox(ctx, "Show markers", &show_markers)
    mu.label(ctx, fmt.tprintf("Body amplitude: %.2f", body_amplitude))
    mu.slider(ctx, &body_amplitude, 0.0, 6.0)
    mu.label(ctx, fmt.tprintf("Body speed: %.2f", body_speed))
    mu.slider(ctx, &body_speed, 0.0, 1.0)
    mu.label(ctx, fmt.tprintf("IK weight: %.2f", ik_weight))
    mu.slider(ctx, &ik_weight, 0.0, 1.0)
    mu.checkbox(ctx, "Manual feet Y", &manual_feet)
    if manual_feet {
      for i in 0 ..< 6 {
        mu.label(ctx, fmt.tprintf("%s foot Y: %.2f", LEG_NAMES[i], foot_y[i]))
        mu.slider(ctx, &foot_y[i], 0.0, 6.0)
      }
    } else {
      mu.label(ctx, fmt.tprintf("Leg lift: %.2f", leg_lift))
      mu.slider(ctx, &leg_lift, 0.0, 6.0)
    }
  }
}
