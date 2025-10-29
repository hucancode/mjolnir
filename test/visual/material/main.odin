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
cube_handle: resources.Handle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-material-textured-cube")
}

setup :: proc(engine: ^mjolnir.Engine) {
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    mjolnir.camera_look_at(camera, {2, 2, 2}, {0.0, 0.0, 0.0})
  }
  world.setup_camera_controller_callbacks(engine.window)
  orbit_controller = world.camera_controller_orbit_init(engine.window)
  world.camera_controller_sync(&orbit_controller, camera)
  cube_geom := geometry.make_cube()
  cube_mesh, mesh_ok := mjolnir.create_mesh(engine, cube_geom)
  if !mesh_ok {
    log.error("material textured cube: mesh creation failed")
    return
  }
  albedo_texture, texture_ok := mjolnir.create_texture(
    engine,
    #load("statue-1275469_1280.jpg"),
    generate_mips = true,
  )
  if !texture_ok {
    log.error("material textured cube: texture load failed")
    return
  }
  material_handle, material_ok := mjolnir.create_material(
    engine,
    {.ALBEDO_TEXTURE},
    type = resources.MaterialType.PBR,
    albedo_handle = albedo_texture,
    roughness_value = 0.35,
    metallic_value = 0.1,
  )
  if !material_ok {
    log.error("material textured cube: material creation failed")
    return
  }
  handle, node, ok := mjolnir.spawn(
    engine,
    world.MeshAttachment {
      handle = cube_mesh,
      material = material_handle,
      cast_shadow = true,
    },
  )
  if ok {
    cube_handle = handle
  }
  _, light_node, light_ok := mjolnir.spawn_directional_light(
    engine,
    {1.0, 1.0, 1.0, 1.0},
    cast_shadow = false,
    position = {3.0, 5.0, 2.0},
  )
  if light_ok {
    mjolnir.rotate(light_node, -math.PI * 0.35, linalg.VECTOR3F32_X_AXIS)
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  if main_camera := mjolnir.get_main_camera(engine); main_camera != nil {
      world.camera_controller_orbit_update(
        &orbit_controller,
        main_camera,
        delta_time,
      )
  }
  mjolnir.rotate(engine, cube_handle, mjolnir.time_since_start(engine), linalg.VECTOR3F32_Y_AXIS)
}
