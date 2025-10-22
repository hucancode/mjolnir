package main

import "../../../mjolnir"
import "../../../mjolnir/geometry"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import "vendor:glfw"

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  mjolnir.run(engine, 800, 600, "visual-lights-no-shadows")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    mjolnir.camera_look_at(camera, {6.0, 4.0, 6.0}, {0.0, 0.0, 0.0})
  }
  plane_geom := geometry.make_quad()
  plane_mesh, plane_mesh_ok := mjolnir.create_mesh(
    engine,
    plane_geom,
  )
  if !plane_mesh_ok {
    log.error("lights no shadows: plane mesh creation failed")
    return
  }
  plane_material, plane_mat_ok := mjolnir.create_material(
    engine,
    type = resources.MaterialType.PBR,
    base_color_factor = {0.2, 0.22, 0.25, 1.0},
    roughness_value = 0.8,
    metallic_value = 0.0,
  )
  if !plane_mat_ok {
    log.error("lights no shadows: plane material creation failed")
    return
  }
  plane_handle, plane_node, plane_spawned := mjolnir.spawn(
    engine,
    world.MeshAttachment {
      handle = plane_mesh,
      material = plane_material,
      cast_shadow = false,
    },
  )
  if plane_spawned {
    mjolnir.scale(plane_node, 6.5)
    mjolnir.translate(plane_node, 0.0, -0.05, 0.0)
  }
  sphere_geom := geometry.make_sphere(32, 16, 1.0)
  sphere_mesh, sphere_mesh_ok := mjolnir.create_mesh(
    engine,
    sphere_geom,
  )
  if !sphere_mesh_ok {
    log.error("lights no shadows: sphere mesh creation failed")
    return
  }
  sphere_material, sphere_mat_ok := mjolnir.create_material(
    engine,
    type = resources.MaterialType.PBR,
    base_color_factor = {0.85, 0.3, 0.3, 1.0},
    roughness_value = 0.35,
    metallic_value = 0.2,
  )
  if !sphere_mat_ok {
    log.error("lights no shadows: sphere material creation failed")
    return
  }
  _, sphere_node, sphere_spawned := mjolnir.spawn(
    engine,
    world.MeshAttachment {
      handle = sphere_mesh,
      material = sphere_material,
      cast_shadow = false,
    },
  )
  if sphere_spawned {
    mjolnir.translate(sphere_node, 0.0, 1.2, 0.0)
    mjolnir.scale(sphere_node, 1.1)
  }
  _, point_node, point_ok := mjolnir.spawn_point_light(
    engine,
    {1.0, 0.85, 0.6, 1.0},
    radius = 5.0,
    cast_shadow = false,
    position = {1.5, 3.0, -1.0},
  )
  _, spot_node, spot_ok := mjolnir.spawn_spot_light(
    engine,
    {0.6, 0.8, 1.0, 1.0},
    radius = 18.0,
    angle = math.PI * 0.25,
    cast_shadow = false,
    position = {-3.0, 5.0, 3.0},
  )
  if spot_ok {
    mjolnir.rotate(spot_node, -math.PI * 0.7, linalg.VECTOR3F32_X_AXIS)
    mjolnir.rotate(spot_node, math.PI * -0.25)
  }
}
