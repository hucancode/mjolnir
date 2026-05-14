package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import mu "vendor:microui"

root_nodes: [dynamic]world.NodeHandle
animation_time: f32 = 0
snake_child_node: world.NodeHandle
tail_layer_index: int = -1

// Live-tweakable parameters
propagation_speed: mu.Real = 0.3
damping: mu.Real = 0.7
drive_frequency: mu.Real = 0.7
drive_amplitude: mu.Real = 0.5 // vertical bob amplitude in world units
drive_enabled: bool = true
stretch_enabled: bool = false
manual_x: mu.Real = 0.0
manual_y: mu.Real = 0.0
manual_z: mu.Real = 0.0

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
  world.main_camera_look_at(&engine.world, {0, 3, 0}, {0, 1, 0})
  root_nodes = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
  for handle in root_nodes {
    node := world.node(&engine.world, handle) or_continue
    for child in node.children {
      snake_child_node = child

      idx, ok := world.add_tail_modifier_layer(
        &engine.world,
        child,
        root_bone_name = "root",
        tail_length = 10,
        propagation_speed = f32(propagation_speed),
        damping = f32(damping),
        weight = 1.0,
        reverse_chain = false,
      )
      if ok {
        tail_layer_index = idx
        log.infof("Added tail modifier to node (layer %d)", tail_layer_index)
      }
    }
  }
  world.spawn_light_point(&engine.world, {-4, 10, 6}, {0.6, 0.7, 1.0, 1.5}, 15.0, false)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if drive_enabled {
    animation_time += delta_time
    amplitude := f32(drive_amplitude)
    freq := f32(drive_frequency)
    y := amplitude * math.sin(animation_time * freq * 2 * math.PI)
    world.translate(&engine.world, snake_child_node, 0, y, 0)
  } else {
    world.translate(
      &engine.world,
      snake_child_node,
      f32(manual_x),
      f32(manual_y),
      f32(manual_z),
    )
  }

  if tail_layer_index >= 0 {
    world.set_tail_modifier_params(
      &engine.world,
      snake_child_node,
      tail_layer_index,
      propagation_speed = f32(propagation_speed),
      damping = f32(damping),
      stretch = stretch_enabled,
    )
  }
}

debug_ui :: proc(engine: ^mjolnir.Engine) {
  ctx := mjolnir.ui_ctx(engine)
  if mu.window(ctx, "Tail Modifier", {20, 300, 320, 440}, {.NO_CLOSE}) {
    mu.layout_row(ctx, {-1}, 0)
    mu.label(ctx, "Propagation speed")
    mu.slider(ctx, &propagation_speed, 0.0, 1.0)
    mu.label(ctx, "Damping")
    mu.slider(ctx, &damping, 0.0, 1.0)
    mu.checkbox(ctx, "Stretch", &stretch_enabled)
    mu.checkbox(ctx, "Animate root", &drive_enabled)
    if drive_enabled {
      mu.label(ctx, "Frequency (Hz)")
      mu.slider(ctx, &drive_frequency, 0.0, 4.0)
      mu.label(ctx, "Amplitude (units)")
      mu.slider(ctx, &drive_amplitude, 0.0, 5.0)
    } else {
      mu.label(ctx, "Manual X")
      mu.slider(ctx, &manual_x, -5.0, 5.0)
      mu.label(ctx, "Manual Y")
      mu.slider(ctx, &manual_y, -5.0, 5.0)
      mu.label(ctx, "Manual Z")
      mu.slider(ctx, &manual_z, -5.0, 5.0)
    }
  }
}
