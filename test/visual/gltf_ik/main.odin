package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"

root_nodes: [dynamic]resources.NodeHandle
character_handle: resources.NodeHandle
target_cube: resources.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-gltf-ik")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  if camera := get_main_camera(engine); camera != nil {
    camera_look_at(camera, {1.5, 1.5, 1.5}, {0, 1, 0})
  }
  root_nodes := load_gltf(engine, "assets/CesiumMan.glb")
  for handle in root_nodes {
    node := get_node(engine, handle) or_continue
    for child in node.children {
      if play_animation(engine, child, "Anim_0") {
        // Setup IK for right arm using FABRIK solver
        // Based on logs: shoulder is at [-0.106, 1.036, 0.043]
        // Arm length is ~0.43m, so target must be within that reach
        target := [3]f32{0.0, 0.0, 0.9} // Closer to shoulder, reachable
        pole := [3]f32{0.3, 0.4, 0.0} // Elbow points right and slightly down

        // Add IK as a layer (layer 1, since animation is on layer 0)
        add_ik_layer(
          engine,
          child,
          bone_names = []string {
            "Skeleton_arm_joint_R", // Root: shoulder
            "Skeleton_arm_joint_R__2_", // Middle: elbow
            "Skeleton_arm_joint_R__3_", // End: hand
          },
          target_pos = target,
          pole_pos = pole,
          weight = 1.0,
        )
        character_handle = child
      }
    }
  }
  spawn_directional_light(
    engine,
    {1.0, 1.0, 1.0, 1.0},
    cast_shadow = true,
    position = {0.0, 5.0, 0.0},
  )
  // Visualize IK target with a small red cube
  target_pos := [3]f32{0.0, 0.0, 0.9}
  cube_mesh := get_builtin_mesh(engine, .CUBE)
  cube_material := get_builtin_material(engine, .RED)
  target_cube = spawn(
    engine,
    target_pos,
    world.MeshAttachment {
      handle = cube_mesh,
      material = cube_material,
      cast_shadow = false,
    },
  )
  mjolnir.scale(engine, target_cube, 0.1)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  using mjolnir
  t := time_since_start(engine) * 0.5
  y := 0.5 + 0.5 * math.sin(t)
  new_target := [3]f32{0.0, y * 2, 0.9}
  pole := [3]f32{0.3, 0.4, 0.0}

  // Update IK layer 1 (animation is on layer 0)
  set_ik_layer_target(
    engine,
    character_handle,
    1, // IK layer index
    new_target,
    pole,
  )

  translate(engine, target_cube, new_target.x, new_target.y, new_target.z)
}
