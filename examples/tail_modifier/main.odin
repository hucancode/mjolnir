package main

import "../../mjolnir"
import anim "../../mjolnir/animation"
import cont "../../mjolnir/containers"
import "../../mjolnir/gpu"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:slice"

root_nodes: [dynamic]world.NodeHandle
animation_time: f32 = 0
snake_child_node: world.NodeHandle
root_bone_modifier: ^anim.SingleBoneRotationModifier

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    world.main_camera_look_at(
      &engine.world,
      {0, 10, 15},
      {0, 3, 0},
    )
    root_nodes = mjolnir.load_gltf(engine, "assets/stuffed_snake_rigged.glb")
    for handle in root_nodes {
      node := cont.get(engine.world.nodes, handle) or_continue
      for child in node.children {
        snake_child_node = child // Store for animation

        // Add single bone rotation modifier to control the root bone
        root_bone_modifier =
          world.add_single_bone_rotation_modifier_layer(
            &engine.world,
            child,
            bone_name = "root",
            weight = 1.0,
            layer_index = -1,
          ) or_else nil
        if root_bone_modifier != nil {
          log.infof("Added root bone rotation modifier")
        }

        // Add tail modifier layer (reacts to root bone rotation)
        // propagation_speed: how strongly bones react to parent changes (0-1)
        //   Higher = stronger immediate reaction to parent
        // damping: how quickly bones return to rest pose (0-1, higher = slower)
        //   Higher = slower return, longer wave propagation
        // reverse_chain: if true, reverses bone order so bone[0] is driver
        //   Use true when root bone is at tail end (need head→tail order)
        success := world.add_tail_modifier_layer(
          &engine.world,
          child,
          root_bone_name = "root",
          tail_length = 10,
          propagation_speed = 0.85, // Strong counter-rotation creates visible drag
          damping = 0.1, // Slow return creates wave propagation
          weight = 1.0,
          reverse_chain = false,
        )
        if success {
          log.infof("Added tail modifier to node")
        }
      }
    }
    light_handle :=
      world.spawn(
        &engine.world,
        {0, 0, 0},
        world.create_directional_light_attachment(
          {1.0, 1.0, 1.0, 1.0},
          10.0,
          false,
        ),
      ) or_else {}
    point_light_handle :=
      world.spawn(
        &engine.world,
        {0, 50, 50},
        world.create_point_light_attachment(
          {1.0, 0.9, 0.8, 1.0},
          1000.0,
          true,
        ),
      ) or_else {}
  }
  engine.update_proc = proc(engine: ^mjolnir.Engine, delta_time: f32) {
    // Animate the root bone directly via the single bone rotation modifier
    // This creates motion that the tail modifier will react to
    animation_time += delta_time
    frequency :: 0.5 // Hz - oscillation speed
    amplitude :: math.PI * 0.35 // Radians - swing angle
    target_angle :=
      amplitude * math.sin(animation_time * frequency * 2 * math.PI)

    // Update the root bone rotation via the modifier
    if root_bone_modifier != nil {
      axis := linalg.Vector3f32{0, 1, 0}
      root_bone_modifier.rotation = linalg.quaternion_angle_axis_f32(
        target_angle,
        axis,
      )
    }
  }
  mjolnir.run(engine, 800, 600, "Tail Modifier")
}
