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

light_handle: resources.Handle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-lights-no-shadows")
}

setup :: proc(engine: ^mjolnir.Engine) {
  if camera := mjolnir.get_main_camera(engine); camera != nil {
    mjolnir.camera_look_at(camera, {6.0, 4.0, 6.0}, {0.0, 0.0, 0.0})
    mjolnir.sync_active_camera_controller(engine)
  }
  // Camera controller is automatically set up by engine
  plane_mesh := engine.rm.builtin_meshes[resources.Primitive.QUAD]
  plane_material := engine.rm.builtin_materials[resources.Color.GRAY]
  plane_handle := mjolnir.spawn(
    engine,
    attachment = world.MeshAttachment {
      handle = plane_mesh,
      material = plane_material,
      cast_shadow = false,
    },
  )
  mjolnir.scale(engine, plane_handle, 6.5)
  mjolnir.translate(engine, plane_handle, 0.0, -0.05, 0.0)
  sphere_mesh := engine.rm.builtin_meshes[resources.Primitive.SPHERE]
  sphere_material := engine.rm.builtin_materials[resources.Color.RED]
  sphere_handle := mjolnir.spawn(
    engine,
    attachment = world.MeshAttachment {
      handle = sphere_mesh,
      material = sphere_material,
      cast_shadow = false,
    },
  )
  mjolnir.translate(engine, sphere_handle, 0.0, 1.2, 0.0)
  mjolnir.scale(engine, sphere_handle, 1.1)
  mjolnir.spawn_point_light(
    engine,
    {1.0, 0.85, 0.6, 1.0},
    radius = 5.0,
    cast_shadow = false,
    position = {0.0, 3.0, 0.0},
  )
  light_handle = mjolnir.spawn_spot_light(
    engine,
    {0.6, 0.8, 1.0, 1.0},
    radius = 18.0,
    angle = math.PI * 0.15,
    cast_shadow = false,
    position = {0, 2, 0},
  )
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  using mjolnir, geometry
  t := time_since_start(engine)
  mjolnir.rotate(
    engine,
    light_handle,
    math.PI * (math.sin(t) * 0.5 + 0.5),
    linalg.VECTOR3F32_X_AXIS,
  )
}
