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


orbit_controller: world.CameraController
light_handle: resources.Handle
main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-shadow-casting")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    mjolnir.camera_look_at(camera, {6.0, 4.5, 6.0}, {0.0, 0.8, 0.0})
  }
  world.setup_camera_controller_callbacks(engine.window)
  orbit_controller = world.camera_controller_orbit_init(engine.window)
  world.camera_controller_sync(&orbit_controller, camera)
  plane_geom := geometry.make_quad()
  plane_mesh, plane_mesh_ok := mjolnir.create_mesh(
    engine,
    plane_geom,
  )
  if !plane_mesh_ok {
    log.error("shadow casting: plane mesh creation failed")
    return
  }
  plane_material, plane_mat_ok := mjolnir.create_material(
    engine,
    type = resources.MaterialType.PBR,
    base_color_factor = {0.35, 0.35, 0.35, 1.0},
    roughness_value = 0.7,
  )
  if !plane_mat_ok {
    log.error("shadow casting: plane material creation failed")
    return
  }
  _, plane_node, plane_spawned := mjolnir.spawn(
    engine,
    world.MeshAttachment {
      handle = plane_mesh,
      material = plane_material,
      cast_shadow = false,
    },
  )
  if plane_spawned {
    mjolnir.scale(plane_node, 7.0)
  }
  cube_geom := geometry.make_cube()
  cube_mesh, cube_mesh_ok := mjolnir.create_mesh(
    engine,
    cube_geom,
  )
  if !cube_mesh_ok {
    log.error("shadow casting: cube mesh creation failed")
    return
  }
  cube_material, cube_mat_ok := mjolnir.create_material(
    engine,
    type = resources.MaterialType.PBR,
    base_color_factor = {0.9, 0.9, 0.95, 1.0},
    roughness_value = 0.25,
    metallic_value = 0.05,
  )
  if !cube_mat_ok {
    log.error("shadow casting: cube material creation failed")
    return
  }
  _, cube_node, cube_spawned := mjolnir.spawn(
    engine,
    world.MeshAttachment {
      handle = cube_mesh,
      material = cube_material,
      cast_shadow = true,
    },
  )
  if cube_spawned {
    mjolnir.translate(cube_node, 0.0, 1.5, 0.0)
    mjolnir.scale(cube_node, 0.8)
  }
  handle, node, ok := mjolnir.spawn_spot_light(
    engine,
    {1.0, 0.95, 0.8, 3.5},
    radius = 18.0,
    angle = math.PI * 0.3,
    position = {0.0, 5.0, 0.0},
  )
  if ok {
    light_handle = handle
    mjolnir.rotate(node, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
  }
}


update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry
  if main_camera := get_main_camera(engine); main_camera != nil {
      world.camera_controller_orbit_update(
        &orbit_controller,
        main_camera,
        delta_time,
      )
  }
  t := time_since_start(engine)
  mjolnir.translate(engine, light_handle, 0, math.sin(t)*0.5+4.5, 0)
}
