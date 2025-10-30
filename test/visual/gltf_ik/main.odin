package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import cgltf "vendor:cgltf"
import "vendor:glfw"

AnimationSceneState :: struct {
  root_nodes:       [dynamic]resources.Handle,
  character_handle: resources.Handle,
  target_cube:      resources.Handle,
}

state := AnimationSceneState{}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, 800, 600, "visual-gltf-ik")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    mjolnir.camera_look_at(camera, {1.0, 0.5, 1.0}, {0.0, 0.3, 0.0})
  }
  nodes, ok := mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
  if !ok {
    log.error("gltf animation: failed to load asset")
    return
  }
  state.root_nodes = nodes
  for handle in nodes {
    mjolnir.scale(engine, handle, 0.4)
    node := mjolnir.get_node(engine, handle)
    if node == nil do continue
    for child in node.children {
      if mjolnir.play_animation(engine, child, "Anim_0") {
        child_node := mjolnir.get_node(engine, child)
        // Setup IK for right arm using FABRIK solver
        // Based on logs: shoulder is at [-0.106, 1.036, 0.043]
        // Arm length is ~0.43m, so target must be within that reach
        target := [3]f32{0.0, 0.0, 0.9} // Closer to shoulder, reachable
        pole := [3]f32{0.3, 0.4, 0.0} // Elbow points right and slightly down
        world.add_ik(
          child_node,
          bone_names = []string {
            "Skeleton_arm_joint_R", // Root: shoulder
            "Skeleton_arm_joint_R__2_", // Middle: elbow
            "Skeleton_arm_joint_R__3_", // End: hand
          },
          target_pos = target,
          pole_pos = pole,
          weight = 1.0,
        )
        world.set_ik_enabled(child_node, 0, true)
        state.character_handle = child
      }
    }
  }
  dir_light_handle := mjolnir.spawn_directional_light(
    engine,
    {1.0, 1.0, 1.0, 1.0},
    cast_shadow = true,
    position = {0.0, 5.0, 0.0},
  )
  mjolnir.rotate(
    engine,
    dir_light_handle,
    math.PI * 0.25,
    linalg.VECTOR3F32_X_AXIS,
  )
  // Visualize IK target with a small red cube using builtin resources
  target_pos := [3]f32{0.0, 0.0, 0.9}
  cube_mesh := mjolnir.get_builtin_mesh(engine, .CUBE)
  cube_material := mjolnir.get_builtin_material(engine, .RED)
  state.target_cube = mjolnir.spawn_at(
    engine,
    target_pos,
    world.MeshAttachment {
      handle = cube_mesh,
      material = cube_material,
      cast_shadow = false,
    },
  )
  mjolnir.scale(engine, state.target_cube, 0.025)
}

update_scene :: proc(engine: ^mjolnir.Engine, dt: f32) {
  if state.character_handle.index == 0 do return
  character_node := mjolnir.get_node(engine, state.character_handle)
  if character_node == nil do return
  // Animate target Y position from 0 to 1 using a smooth sine wave
  t := mjolnir.time_since_start(engine) * 0.5 // Slow down the animation (2 second period)
  y := 0.5 + 0.5 * math.sin(t) // Oscillate between 0 and 1
  // Update IK target position
  new_target := [3]f32{0.0, y, 0.6}
  pole := [3]f32{0.3, 0.4, 0.0}
  world.set_ik_target(
    character_node,
    0, // IK config index
    new_target,
    pole,
  )
  mjolnir.translate(
    engine,
    state.target_cube,
    new_target.x,
    new_target.y,
    new_target.z,
  )
}
