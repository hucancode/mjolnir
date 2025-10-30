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
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup_scene
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-shadow-casting")
}

setup_scene :: proc(engine: ^mjolnir.Engine) {
  camera := mjolnir.get_main_camera(engine)
  if camera != nil {
    mjolnir.camera_look_at(camera, {6.0, 4.5, 6.0}, {0.0, 0.8, 0.0})
    mjolnir.sync_active_camera_controller(engine)
  }
  // Camera controller is automatically set up by engine
  plane_mesh := engine.rm.builtin_meshes[resources.Primitive.QUAD]
  plane_material := engine.rm.builtin_materials[resources.Color.GRAY]
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
  cube_mesh := engine.rm.builtin_meshes[resources.Primitive.CUBE]
  cube_material := engine.rm.builtin_materials[resources.Color.WHITE]
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
  t := time_since_start(engine)
  mjolnir.translate(engine, light_handle, 0, math.sin(t)*0.5+4.5, 0)
}
