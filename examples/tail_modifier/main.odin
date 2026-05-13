package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import mu "vendor:microui"

root_nodes: [dynamic]world.NodeHandle
animation_time: f32 = 0
snake_child_node: world.NodeHandle
root_bone_modifier: ^anim.SingleBoneRotationModifier
tail_layer_index: int = -1

// Live-tweakable parameters
propagation_delay: mu.Real = 0.08
influence_falloff: mu.Real = 0.85
stiffness: mu.Real = 45.0
damping_ratio: mu.Real = 0.45
drive_frequency: mu.Real = 0.5
drive_amplitude_deg: mu.Real = 63.0 // ~math.PI * 0.35 in degrees
drive_enabled: bool = true

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.pre_render_proc = debug_ui
  mjolnir.run(engine, 900, 700, "Tail Modifier")
}

setup :: proc(engine: ^mjolnir.Engine) {
  engine.debug_ui_enabled = true
  world.main_camera_look_at(&engine.world, {0, 10, 15}, {0, 3, 0})
  root_nodes = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
  for handle in root_nodes {
    node := world.node(&engine.world, handle) or_continue
    for child in node.children {
      snake_child_node = child

      root_bone_modifier =
        world.add_single_bone_rotation_modifier_layer(
          &engine.world,
          child,
          bone_name = "root",
          weight = 1.0,
          layer_index = -1,
        ) or_else nil

      if world.add_tail_modifier_layer(
        &engine.world,
        child,
        root_bone_name = "root",
        tail_length = 10,
        propagation_delay = f32(propagation_delay),
        influence_falloff = f32(influence_falloff),
        stiffness = f32(stiffness),
        damping_ratio = f32(damping_ratio),
        weight = 1.0,
        reverse_chain = false,
      ) {
        tail_layer_index = 1 // root-bone modifier at 0, tail at 1
        log.infof("Added tail modifier to node (layer %d)", tail_layer_index)
      }
    }
  }
  world.spawn(
    &engine.world,
    {0, 0, 0},
    world.create_directional_light_attachment(
      {1.0, 1.0, 1.0, 1.0},
      10.0,
      false,
    ),
  )
  world.spawn(
    &engine.world,
    {0, 50, 50},
    world.create_point_light_attachment({1.0, 0.9, 0.8, 1.0}, 1000.0, true),
  )
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if drive_enabled {
    animation_time += delta_time
  }
  if root_bone_modifier != nil {
    amplitude := f32(drive_amplitude_deg) * math.PI / 180.0
    freq := f32(drive_frequency)
    target_angle := amplitude * math.sin(animation_time * freq * 2 * math.PI)
    root_bone_modifier.rotation = linalg.quaternion_angle_axis_f32(
      target_angle,
      linalg.Vector3f32{0, 1, 0},
    )
  }

  if tail_layer_index >= 0 {
    world.set_tail_modifier_params(
      &engine.world,
      snake_child_node,
      tail_layer_index,
      propagation_delay = f32(propagation_delay),
      influence_falloff = f32(influence_falloff),
      stiffness = f32(stiffness),
      damping_ratio = f32(damping_ratio),
    )
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := &engine.render.debug_ui.ctx
  if mu.window(ctx, "Tail Modifier", {20, 20, 320, 360}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)

    mu.label(ctx, "--- Spring dynamics ---")
    mu.label(ctx, "Propagation delay (s):")
    mu.slider(ctx, &propagation_delay, 0.0, 0.5)
    mu.label(ctx, "Influence falloff (0..1):")
    mu.slider(ctx, &influence_falloff, 0.0, 1.0)
    mu.label(ctx, "Stiffness (rad/s^2):")
    mu.slider(ctx, &stiffness, 0.0, 300.0)
    mu.label(ctx, "Damping ratio:")
    mu.slider(ctx, &damping_ratio, 0.0, 2.0)

    mu.label(ctx, "--- Drive signal ---")
    mu.checkbox(ctx, "Animate root", &drive_enabled)
    mu.label(ctx, "Frequency (Hz):")
    mu.slider(ctx, &drive_frequency, 0.0, 4.0)
    mu.label(ctx, "Amplitude (deg):")
    mu.slider(ctx, &drive_amplitude_deg, 0.0, 180.0)
  }
}
