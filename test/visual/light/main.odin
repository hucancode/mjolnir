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

LightSceneState :: struct {
  run_seconds: f32,
  start_time:  time.Time,
}

state := LightSceneState{run_seconds = 4.0}

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update_scene
  mjolnir.run(engine, 1280, 720, "visual-lights-no-shadows")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  state.start_time = time.now()

  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    geometry.camera_perspective(camera, math.PI * 0.27, 1280.0 / 720.0, 0.05, 150.0)
    geometry.camera_look_at(camera, {6.0, 4.0, 6.0}, {0.0, 0.0, 0.0})
  }

  plane_geom := geometry.make_quad()

  plane_mesh, plane_mesh_ok := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    plane_geom,
  )
  if !plane_mesh_ok {
    log.error("lights no shadows: plane mesh creation failed")
    return
  }

  plane_material, plane_mat_ok := resources.create_material_handle(
    &engine.resource_manager,
    type = resources.MaterialType.PBR,
    base_color_factor = {0.2, 0.22, 0.25, 1.0},
    roughness_value = 0.8,
    metallic_value = 0.0,
  )
  if !plane_mat_ok {
    log.error("lights no shadows: plane material creation failed")
    return
  }

  plane_handle, plane_node, plane_spawned := world.spawn(
    &engine.world,
    world.MeshAttachment {
      handle      = plane_mesh,
      material    = plane_material,
      cast_shadow = false,
    },
    &engine.resource_manager,
  )
  if plane_spawned {
    world.scale(plane_node, 6.5)
    world.translate(plane_node, 0.0, -0.05, 0.0)
  }

  sphere_geom := geometry.make_sphere(32, 16, 1.0)

  sphere_mesh, sphere_mesh_ok := resources.create_mesh_handle(
    &engine.gpu_context,
    &engine.resource_manager,
    sphere_geom,
  )
  if !sphere_mesh_ok {
    log.error("lights no shadows: sphere mesh creation failed")
    return
  }

  sphere_material, sphere_mat_ok := resources.create_material_handle(
    &engine.resource_manager,
    type = resources.MaterialType.PBR,
    base_color_factor = {0.85, 0.3, 0.3, 1.0},
    roughness_value = 0.35,
    metallic_value = 0.2,
  )
  if !sphere_mat_ok {
    log.error("lights no shadows: sphere material creation failed")
    return
  }

  _, sphere_node, sphere_spawned := world.spawn(
    &engine.world,
    world.MeshAttachment {
      handle      = sphere_mesh,
      material    = sphere_material,
      cast_shadow = false,
    },
    &engine.resource_manager,
  )
  if sphere_spawned {
    world.translate(sphere_node, 0.0, 1.2, 0.0)
    world.scale(sphere_node, 1.1)
  }

  point_handle, point_node, point_ok := world.spawn(&engine.world, nil, &engine.resource_manager)
  if point_ok {
    attachment, attach_ok := world.create_point_light_attachment(
      point_handle,
      &engine.resource_manager,
      &engine.gpu_context,
      {1.0, 0.85, 0.6, 1.0},
      radius = 5.0,
      cast_shadow = false,
    )
    if attach_ok {
      point_node.attachment = attachment
      world.translate(point_node, 1.5, 3.0, -1.0)
    }
  }

  spot_handle, spot_node, spot_ok := world.spawn(&engine.world, nil, &engine.resource_manager)
  if spot_ok {
    spot_attachment, attach_ok := world.create_spot_light_attachment(
      spot_handle,
      &engine.resource_manager,
      &engine.gpu_context,
      {0.6, 0.8, 1.0, 1.0},
      radius = 18.0,
      angle = math.PI * 0.25,
      cast_shadow = false,
    )
    if attach_ok {
      spot_node.attachment = spot_attachment
      world.translate(spot_node, -3.0, 5.0, 3.0)
      world.rotate(spot_node, -math.PI * 0.7, linalg.VECTOR3F32_X_AXIS)
      world.rotate(spot_node, math.PI * -0.25)
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
