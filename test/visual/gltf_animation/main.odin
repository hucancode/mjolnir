package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import cgltf "vendor:cgltf"
import "vendor:glfw"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"

AnimationSceneState :: struct {
  root_nodes:    [dynamic]resources.Handle,
  frame_counter: int,
}

state := AnimationSceneState{}

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  mjolnir.run(engine, 800, 600, "visual-gltf-animation")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    resources.camera_look_at(camera, {1.0, 0.5, 1.0}, {0.0, 0.3, 0.0})
  }

  nodes, result := world.load_gltf(
    &engine.world,
    &engine.resource_manager,
    &engine.gpu_context,
    "assets/CesiumMan.glb",
  )
  if result != cgltf.result.success {
    log.errorf("gltf animation: failed to load asset (result=%v)", result)
    return
  }
  state.root_nodes = nodes

  for handle in nodes {
    world.node_handle_scale(&engine.world, handle, 0.4)
    node := world.get_node(&engine.world, handle)
    if node == nil do continue
    for child in node.children {
      child_node := world.get_node(&engine.world, child)
      if child_node == nil do continue
      if _, has_mesh := child_node.attachment.(world.MeshAttachment); has_mesh {
        mjolnir.play_animation(engine, child, "Anim_0")
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

  _, _, _ = mjolnir.spawn_point_light(
    engine,
    {0.8, 0.7, 0.6, 0.5},
    radius = 1.5,
    position = {1.5, 3.5, 2.0},
  )
}

update_scene :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  state.frame_counter += 1

  if state.root_nodes != nil {
    rotation := delta_time * math.PI * 0.05
    for handle in state.root_nodes {
      world.node_handle_rotate_angle(
        &engine.world,
        handle,
        rotation,
        linalg.VECTOR3F32_Y_AXIS,
      )
    }
  }
}
