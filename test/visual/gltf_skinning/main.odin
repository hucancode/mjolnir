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

SkinSceneState :: struct {
  nodes:      [dynamic]resources.Handle,
}

state := SkinSceneState{}

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, 800, 600, "visual-gltf-skinning")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    resources.camera_look_at(camera, {-3.5, 2.0, 1.8}, {0.0, 1.0, 0.0})
  }

  nodes, result := world.load_gltf(
    &engine.world,
    &engine.resource_manager,
    &engine.gpu_context,
    "assets/CesiumMan.glb",
  )
  if result != cgltf.result.success {
    log.errorf("gltf skinning: failed to load asset (result=%v)", result)
    return
  }
  state.nodes = nodes

  for handle in nodes {
    world.node_handle_scale(&engine.world, handle, 1.2)
    world.node_handle_translate(&engine.world, handle, 0.0, 0.0, 0.0)
  }

  light_handle, light_node, light_ok := world.spawn(&engine.world, nil, &engine.resource_manager)
  if light_ok {
    light_attachment, attach_ok := world.create_directional_light_attachment(
      light_handle,
      &engine.resource_manager,
      &engine.gpu_context,
      {1.0, 1.0, 1.0, 1.0},
      cast_shadow = true,
    )
    if attach_ok {
      light_node.attachment = light_attachment
      world.translate(light_node, -3.0, 5.0, -2.0)
      world.rotate(light_node, math.PI * -0.4, linalg.VECTOR3F32_X_AXIS)
      world.rotate(light_node, math.PI * 0.35)
    }
  }
}

update_scene :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if state.nodes != nil {
    rotation := delta_time * math.PI * 0.15
    for handle in state.nodes {
      world.node_handle_rotate_angle(&engine.world, handle, rotation, linalg.VECTOR3F32_Y_AXIS)
    }
  }
}
