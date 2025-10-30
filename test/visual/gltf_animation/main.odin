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
  root_nodes:    [dynamic]resources.Handle,
  frame_counter: int,
}

state := AnimationSceneState{}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, 800, 600, "visual-gltf-animation")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(camera, {1.0, 0.5, 1.0}, {0.0, 0.3, 0.0})
  }
  state.root_nodes = mjolnir.load_gltf(engine, "assets/CesiumMan.glb")
  for handle in state.root_nodes {
    mjolnir.scale(engine, handle, 0.4)
    node := mjolnir.get_node(engine, handle)
    if node == nil do continue
    for child in node.children {
      if mjolnir.play_animation(engine, child, "Anim_0") {
        break
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
  mjolnir.spawn_point_light(
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
      mjolnir.rotate_by(engine, handle, rotation, linalg.VECTOR3F32_Y_AXIS)
    }
  }
}
