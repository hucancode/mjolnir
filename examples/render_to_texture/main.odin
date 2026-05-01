package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:math/linalg"

rtt_camera_handle: world.CameraHandle
rtt_material_handle: world.MaterialHandle
spinner_handle: world.NodeHandle

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = setup
  engine.update_proc = update
  engine.post_render_proc = on_post_render
  mjolnir.run(engine, 800, 600, "Render To Texture")
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {5, 3, 6}, {0, 1, 0})

  ground_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XZ)
  ground_material := world.get_builtin_material(&engine.world, .GRAY)
  ground_handle :=
    world.spawn(
      &engine.world,
      {0, 0, 0},
      world.MeshAttachment {
        handle = ground_mesh,
        material = ground_material,
      },
    ) or_else {}
  world.scale(&engine.world, ground_handle, 6.0)

  world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .RED,
    position = {-1.5, 0.5, 0},
  )
  world.spawn_primitive_mesh(
    &engine.world,
    .SPHERE,
    .GREEN,
    position = {0, 0.6, 1.0},
    scale_factor = 0.6,
  )
  world.spawn_primitive_mesh(
    &engine.world,
    .CONE,
    .BLUE,
    position = {1.5, 0.5, -0.5},
  )

  spinner_handle = world.spawn_primitive_mesh(
    &engine.world,
    .CUBE,
    .YELLOW,
    position = {0, 1.8, 0},
    scale_factor = 0.4,
  )

  world.spawn(
    &engine.world,
    {0, 3, 1.5},
    world.create_point_light_attachment({1.0, 0.6, 0.3, 1.0}, 12.0, false),
  )

  // Off-screen camera looking at scene from a different angle (top-down).
  // No POST_PROCESS pass for cheaper rendering of the texture.
  rtt_camera_handle = world.create_camera(
    &engine.world,
    512,
    512,
    {.GEOMETRY, .LIGHTING, .TRANSPARENCY},
    {0, 8, 0.01},
    {0, 0, 0},
    math.PI * 0.5,
    0.1,
    100.0,
  )

  rtt_material_handle = world.create_material(&engine.world, {.ALBEDO_TEXTURE})

  // Quad on the back wall displays whatever rtt_camera renders.
  display_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XY)
  display_handle :=
    world.spawn(
      &engine.world,
      {0, 2.5, -3.5},
      world.MeshAttachment {
        handle = display_mesh,
        material = rtt_material_handle,
        cast_shadow = false,
      },
    ) or_else {}
  world.scale(&engine.world, display_handle, 3.0)
}

update :: proc(engine: ^mjolnir.Engine, delta_time: f32) {
  t := mjolnir.time_since_start(engine)
  world.rotate(
    &engine.world,
    spinner_handle,
    t,
    linalg.VECTOR3F32_Y_AXIS,
  )
}

on_post_render :: proc(engine: ^mjolnir.Engine) {
  if material, ok := world.material(&engine.world, rtt_material_handle); ok {
    material.albedo = mjolnir.get_camera_attachment(
      engine,
      rtt_camera_handle,
      .FINAL_IMAGE,
      engine.frame_index,
    )
    world.stage_material_data(&engine.world.staging, rtt_material_handle)
  }
}
