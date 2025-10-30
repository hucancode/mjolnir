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

GLTFSceneState :: struct {
  nodes: [dynamic]resources.Handle,
}

state := GLTFSceneState{}

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, 800, 600, "visual-gltf-static")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(camera, {3.5, 2.2, 3.5}, {0.0, 1.0, 0.0})
  }
  state.nodes = mjolnir.load_gltf(engine, "assets/Duck.glb")
  for handle in state.nodes {
    mjolnir.scale(engine, handle, 0.4)
    mjolnir.translate(engine, handle, 0.0, 0.0, 0.0)
  }
  light_handle := mjolnir.spawn_directional_light(
    engine,
    {1.0, 1.0, 1.0, 1.0},
    cast_shadow = false,
    position = {-4.0, 6.0, 2.0},
  )
  mjolnir.rotate(
    engine,
    light_handle,
    math.PI * -0.5,
    linalg.VECTOR3F32_X_AXIS,
  )
  mjolnir.rotate(engine, light_handle, math.PI * 0.35)
}

update_scene :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  rotation := delta_time * math.PI * 0.1
  for handle in state.nodes {
    mjolnir.rotate_by(engine, handle, rotation, linalg.VECTOR3F32_Y_AXIS)
  }
}
