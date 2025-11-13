package main

import "../../../mjolnir"
import "../../../mjolnir/resources"
import "../../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"

cube_handle: resources.Handle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-material-textured-cube")
}

setup :: proc(engine: ^mjolnir.Engine) {
  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(camera, {2, 2, 2}, {0.0, 0.0, 0.0})
    mjolnir.sync_active_camera_controller(engine)
  }
  cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  albedo_texture := mjolnir.create_texture(
    engine,
    #load("statue-1275469_1280.jpg"),
    generate_mips = true,
  )
  material_handle := mjolnir.create_material(
    engine,
    {.ALBEDO_TEXTURE},
    type = resources.MaterialType.PBR,
    albedo_handle = albedo_texture,
    roughness_value = 0.35,
    metallic_value = 0.1,
  )
  cube_handle = mjolnir.spawn(
    engine,
    attachment = world.MeshAttachment {
      handle = cube_mesh,
      material = material_handle,
      cast_shadow = true,
    },
  )
  light_handle := mjolnir.spawn_directional_light(
    engine,
    {1.0, 1.0, 1.0, 1.0},
    cast_shadow = false,
    position = {3.0, 5.0, 2.0},
  )
  mjolnir.rotate(
    engine,
    light_handle,
    -math.PI * 0.35,
    linalg.VECTOR3F32_X_AXIS,
  )
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  mjolnir.rotate(
    engine,
    cube_handle,
    mjolnir.time_since_start(engine),
    linalg.VECTOR3F32_Y_AXIS,
  )
}
