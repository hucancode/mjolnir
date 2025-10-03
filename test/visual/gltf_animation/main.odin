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
  run_seconds:   f32,
  start_time:    time.Time,
  capture_frame: int,
}

state := AnimationSceneState{run_seconds = 8.0, capture_frame = 100}

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, 1280, 720, "visual-gltf-animation")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  state.start_time = time.now()
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    geometry.camera_perspective(camera, math.PI * 0.28, 1280.0 / 720.0, 0.05, 120.0)
    geometry.camera_look_at(camera, {1.0, 0.5, 1.0}, {0.0, 0.3, 0.0})
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
    if node == nil {
      continue
    }
    for child in node.children {
      child_node := world.get_node(&engine.world, child)
      if child_node == nil {
        continue
      }
      if _, has_mesh := child_node.attachment.(world.MeshAttachment); has_mesh {
        _ = world.play_animation(
          &engine.world,
          &engine.resource_manager,
          child,
          "Anim_0",
        )
      }
    }
  }

  dir_light_handle, dir_light_node, dir_ok := world.spawn(&engine.world, nil, &engine.resource_manager)
  if dir_ok {
    attachment, attach_ok := world.create_directional_light_attachment(
      dir_light_handle,
      &engine.resource_manager,
      &engine.gpu_context,
      {1.0, 1.0, 1.0, 1.0},
      cast_shadow = true,
    )
    if attach_ok {
      dir_light_node.attachment = attachment
      world.translate(dir_light_node, -6.0, 8.0, 6.0)
      world.rotate(dir_light_node, math.PI * -0.45, linalg.VECTOR3F32_X_AXIS)
      world.rotate(dir_light_node, math.PI * 0.5)
    }
  }

  point_handle, point_node, point_ok := world.spawn(
    &engine.world,
    nil,
    &engine.resource_manager,
  )
  if point_ok {
    point_attachment, point_attach := world.create_point_light_attachment(
      point_handle,
      &engine.resource_manager,
      &engine.gpu_context,
      {0.8, 0.7, 0.6, 0.5},
      radius = 1.5,
      cast_shadow = false,
    )
    if point_attach {
      point_node.attachment = point_attachment
      world.translate(point_node, 1.5, 3.5, 2.0)
    }
  }
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

  elapsed := f32(time.duration_seconds(time.since(state.start_time)))
  if elapsed >= state.run_seconds && state.frame_counter >= state.capture_frame {
    glfw.SetWindowShouldClose(engine.window, true)
  }
}
