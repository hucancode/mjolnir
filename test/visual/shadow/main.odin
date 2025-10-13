package main

import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import "vendor:glfw"
import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"

ShadowSceneState :: struct {
  run_seconds: f32,
  start_time:  time.Time,
}

state := ShadowSceneState{run_seconds = 5.0}

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, 800, 600, "visual-shadow-casting")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  state.start_time = time.now()

  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    geometry.camera_perspective(camera, math.PI * 0.27, 800.0 / 600.0, 0.05, 150.0)
    geometry.camera_look_at(camera, {6.0, 4.5, 6.0}, {0.0, 0.8, 0.0})
  }

  plane_geom := geometry.make_quad()
  plane_mesh, plane_mesh_ok := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    plane_geom,
  )
  if !plane_mesh_ok {
    log.error("shadow casting: plane mesh creation failed")
    return
  }
  plane_material, plane_mat_ok := resources.create_material_handle(
    &engine.resource_manager,
    type = resources.MaterialType.PBR,
    base_color_factor = {0.35, 0.35, 0.35, 1.0},
    roughness_value = 0.7,
  )
  if !plane_mat_ok {
    log.error("shadow casting: plane material creation failed")
    return
  }
  _, plane_node, plane_spawned := world.spawn(
    &engine.world,
    world.MeshAttachment {
      handle      = plane_mesh,
      material    = plane_material,
      cast_shadow = false,
    },
    &engine.resource_manager,
  )
  if plane_spawned {
    world.scale(plane_node, 7.0)
  }

  cube_geom := geometry.make_cube()
  cube_mesh, cube_mesh_ok := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    cube_geom,
  )
  if !cube_mesh_ok {
    log.error("shadow casting: cube mesh creation failed")
    return
  }
  cube_material, cube_mat_ok := resources.create_material_handle(
    &engine.resource_manager,
    type = resources.MaterialType.PBR,
    base_color_factor = {0.9, 0.9, 0.95, 1.0},
    roughness_value = 0.25,
    metallic_value = 0.05,
  )
  if !cube_mat_ok {
    log.error("shadow casting: cube material creation failed")
    return
  }
  _, cube_node, cube_spawned := world.spawn(
    &engine.world,
    world.MeshAttachment {
      handle      = cube_mesh,
      material    = cube_material,
      cast_shadow = true,
    },
    &engine.resource_manager,
  )
  if cube_spawned {
    world.translate(cube_node, 0.0, 1.5, 0.0)
    world.scale(cube_node, 0.8)
  }

  light_handle, light_node, light_ok := world.spawn(
    &engine.world,
    nil,
    &engine.resource_manager,
  )
  if light_ok {
    attachment, attach_ok := world.create_spot_light_attachment(
      light_handle,
      &engine.resource_manager,
      &engine.gpu_context,
      {1.0, 0.95, 0.8, 3.5},
      radius = 18.0,
      angle = math.PI * 0.3,
      cast_shadow = true,
    )
    if attach_ok {
      light_node.attachment = attachment
      world.translate(light_node, 0.0, 5.0, 0.0)
      world.rotate(light_node, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
    }
  }
}

update_scene :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  _ = delta_time
  elapsed := f32(time.duration_seconds(time.since(state.start_time)))
  if elapsed >= state.run_seconds {
    glfw.SetWindowShouldClose(engine.window, true)
  }
}
