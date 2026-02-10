package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"

root_nodes: [dynamic]mjolnir.NodeHandle
character_handle: mjolnir.NodeHandle
target_cube: mjolnir.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-gltf-ik")
}

setup :: proc(engine: ^mjolnir.Engine) {
  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(camera, {1.5, 1.5, 1.5}, {0, 1, 0})
    mjolnir.sync_active_camera_controller(engine)
  }
  root_nodes := mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
  for handle in root_nodes {
    node := mjolnir.get_node(engine, handle) or_continue
    for child in node.children {
      if mjolnir.play_animation(engine, child, "Anim_0") {
        // Setup IK for right arm using FABRIK solver
        // Based on logs: shoulder is at [-0.106, 1.036, 0.043]
        // Arm length is ~0.43m, so target must be within that reach
        target := [3]f32{0.0, 0.0, 0.9} // Closer to shoulder, reachable
        pole := [3]f32{0.3, 0.4, 0.0} // Elbow points right and slightly down

        // Add IK as a layer (layer 1, since animation is on layer 0)
        mjolnir.add_ik_layer(
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
  mjolnir.spawn_directional_light(
    engine,
    {1.0, 1.0, 1.0, 1.0},
    cast_shadow = true,
  )
  // Visualize IK target with a small red cube
  target_pos := [3]f32{0.0, 0.0, 0.9}
  cube_mesh := mjolnir.get_builtin_mesh(engine, .CUBE)
  cube_material := mjolnir.get_builtin_material(engine, .RED)
  target_cube = mjolnir.spawn(
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
  t := mjolnir.time_since_start(engine) * 0.5
  y := 0.5 + 0.5 * math.sin(t)
  new_target := [3]f32{0.0, y * 2, 0.9}
  pole := [3]f32{0.3, 0.4, 0.0}

  // Update IK layer 1 (animation is on layer 0)
  mjolnir.set_ik_layer_target(
    engine,
    character_handle,
    1, // IK layer index
    new_target,
    pole,
  )
  mjolnir.translate(engine, target_cube, new_target.x, new_target.y, new_target.z)
}
