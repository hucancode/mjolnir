package main

import "../../mjolnir"
import "../../mjolnir/geometry"
import "../../mjolnir/resources"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:time"
import "vendor:glfw"

light_handle: resources.NodeHandle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-shadow-casting")
}

setup :: proc(engine: ^mjolnir.Engine) {
  using mjolnir
  if camera := get_main_camera(engine); camera != nil {
    camera_look_at(camera, {6.0, 4.5, 6.0}, {0.0, 0.8, 0.0})
    sync_active_camera_controller(engine)
  }
  plane_mesh := engine.rm.builtin_meshes[resources.Primitive.QUAD]
  plane_material := engine.rm.builtin_materials[resources.Color.GRAY]
  plane_handle := spawn(
    engine,
    attachment = world.MeshAttachment {
      handle = plane_mesh,
      material = plane_material,
      cast_shadow = false,
    },
  )
  scale(engine, plane_handle, 7.0)
  cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  cube_material := engine.rm.builtin_materials[resources.Color.WHITE]
  cube_handle := spawn(
    engine,
    attachment = world.MeshAttachment {
      handle = cube_mesh,
      material = cube_material,
      cast_shadow = true,
    },
  )
  translate(engine, cube_handle, 0.0, 1.5, 0.0)
  scale(engine, cube_handle, 0.8)
  light_handle = spawn_spot_light(
    engine,
    {1.0, 0.95, 0.8, 3.5},
    radius = 18.0,
    angle = math.PI * 0.3,
    position = {0.0, 5.0, 0.0},
  )
  rotate(engine, light_handle, math.PI * 0.5, linalg.VECTOR3F32_X_AXIS)
}


update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir
  t := time_since_start(engine)
  translate(engine, light_handle, 0, math.sin(t) * 0.5 + 4.5, 0)
}
