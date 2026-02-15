package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"
import "vendor:glfw"

cube_handle: world.NodeHandle

main :: proc() {
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  mjolnir.run(engine, 800, 600, "visual-material-textured-cube")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(
    &engine.world,
    engine.world.main_camera,
    {2, 2, 2},
    {0.0, 0.0, 0.0},
  )
  cube_mesh := world.get_builtin_mesh(&engine.world, .CUBE)
  albedo_texture := mjolnir.create_texture(
    engine,
    #load("statue-1275469_1280.jpg"),
    generate_mips = true,
  )
  material_handle := world.create_material(
    &engine.world,
    {.ALBEDO_TEXTURE},
    .PBR,
    albedo_handle = transmute(world.Image2DHandle)albedo_texture,
    roughness_value = 0.35,
    metallic_value = 0.1,
  )
  cube_handle =
    world.spawn(
      &engine.world,
      {0, 0, 0},
      attachment = world.MeshAttachment {
        handle = cube_mesh,
        material = material_handle,
        cast_shadow = true,
      },
    ) or_else {}
  q1 := linalg.quaternion_angle_axis(-math.PI * 0.35, linalg.VECTOR3F32_Y_AXIS)
  q2 := linalg.quaternion_angle_axis(-math.PI * 0.35, linalg.VECTOR3F32_X_AXIS)
  light_handle :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.create_directional_light_attachment(
        {1.0, 1.0, 1.0, 1.0},
        10.0,
        false,
      ),
    ) or_else {}
  if light_node, ok := cont.get(engine.world.nodes, light_handle); ok {
    light_node.transform.rotation = q2 * q1
    light_node.transform.is_dirty = true
  }
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  world.rotate(
    &engine.world,
    cube_handle,
    mjolnir.time_since_start(engine),
    linalg.VECTOR3F32_Y_AXIS,
  )
}
