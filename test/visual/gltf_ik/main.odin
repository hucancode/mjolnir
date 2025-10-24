package main

import "../../../mjolnir"
import "../../../mjolnir/geometry"
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
      child_node := mjolnir.get_node(engine, child)
      if child_node == nil do continue
      if _, has_mesh := child_node.attachment.(world.MeshAttachment);
         has_mesh {
        mjolnir.play_animation(engine, child, "Anim_0")

        // Setup IK for right arm using FABRIK solver
        // Based on logs: shoulder is at [-0.106, 1.036, 0.043]
        // Arm length is ~0.43m, so target must be within that reach
        target := [3]f32{0.0, 0.0, 0.9} // Closer to shoulder, reachable
        pole := [3]f32{0.3, 0.4, 0.0}   // Elbow points right and slightly down

        world.add_ik(
          child_node,
          bone_names = []string{
            "Skeleton_arm_joint_R",      // Root: shoulder
            "Skeleton_arm_joint_R__2_",  // Middle: elbow
            "Skeleton_arm_joint_R__3_",  // End: hand
          },
          target_pos = target,
          pole_pos = pole,
          weight = 1.0,
        )

        // Enable IK immediately
        world.set_ik_enabled(child_node, 0, true)
        state.character_handle = child
      }
    }
  }
  dir_light_handle, dir_light_node, dir_ok := mjolnir.spawn_directional_light(
    engine,
    {1.0, 1.0, 1.0, 1.0},
    cast_shadow = true,
    position = {0.0, 5.0, 0.0},
  )
  if dir_ok {
    mjolnir.rotate(dir_light_node, math.PI * 0.25, linalg.VECTOR3F32_X_AXIS)
  }

  // Visualize IK target with a small red cube
  target_pos := [3]f32{0.0, 0.0, 0.9}
  cube_geom := geometry.make_cube({1.0, 0.2, 0.2, 1.0})
  cube_mesh, mesh_ok := mjolnir.create_mesh(engine, cube_geom)
  if mesh_ok {
    cube_material := mjolnir.create_material(
      engine,
      base_color_factor = [4]f32{1.0, 0.2, 0.2, 1.0},
      metallic_value = 0.0,
      roughness_value = 0.8,
    )
    cube_handle, _, ok := mjolnir.spawn_at(
      engine,
      target_pos,
      world.MeshAttachment {
        handle = cube_mesh,
        material = cube_material,
        cast_shadow = false,
      },
    )
    if ok {
      mjolnir.scale(engine, cube_handle, 0.025)
      state.target_cube = cube_handle
    }
  }
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

  // Update target cube visualization position
  if state.target_cube.index != 0 {
    cube_node := mjolnir.get_node(engine, state.target_cube)
    if cube_node != nil {
      mjolnir.translate(cube_node, new_target.x, new_target.y, new_target.z)
    }
  }
}
