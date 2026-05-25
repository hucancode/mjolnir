package main

import "../../mjolnir"
import "../../mjolnir/world"
import "core:math"
import "core:math/linalg"

rtt_camera_handle: world.CameraHandle
rtt_material_handle: world.MaterialHandle
spinner_handle: world.NodeHandle

main :: proc() {
  mjolnir.run_app({
    title       = "Render To Texture",
    setup       = setup,
    update      = update,
    post_render = on_post_render,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  world.main_camera_look_at(&engine.world, {5, 3, 6}, {0, 1, 0})

  world.spawn_ground(&engine.world, 6.0)

  world.spawn_primitive_mesh(&engine.world, .CUBE,   .RED,   position = {-1.5, 0.5, 0})
  world.spawn_primitive_mesh(&engine.world, .SPHERE, .GREEN, position = {0, 0.6, 1.0}, scale_factor = 0.6)
  world.spawn_primitive_mesh(&engine.world, .CONE,   .BLUE,  position = {1.5, 0.5, -0.5})
  spinner_handle = world.spawn_primitive_mesh(&engine.world, .CUBE, .YELLOW, position = {0, 1.8, 0}, scale_factor = 0.4)

  world.spawn_light_point(&engine.world, {0, 3, 1.5}, {1.0, 0.6, 0.3, 1.0}, 12.0, false)

  rtt_camera_handle = mjolnir.create_camera(engine, 512, 512, {.GEOMETRY, .LIGHTING, .TRANSPARENCY}, {0, 8, 0.01}, {0, 0, 0}, math.PI * 0.5, 0.1, 100.0)
  rtt_material_handle = world.create_material(&engine.world, {.ALBEDO_TEXTURE})

  display_mesh := world.get_builtin_mesh(&engine.world, .QUAD_XY)
  display_handle := world.spawn(&engine.world, {0, 2.5, -3.5}, world.MeshAttachment{handle = display_mesh, material = rtt_material_handle, cast_shadow = false})
  world.scale(&engine.world, display_handle, 3.0)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  world.rotate(&engine.world, spinner_handle, mjolnir.time_since_start(engine), linalg.VECTOR3F32_Y_AXIS)
}

on_post_render :: proc(engine: ^mjolnir.Engine) {
  if mat, ok := world.material(&engine.world, rtt_material_handle); ok {
    mat.albedo = mjolnir.get_camera_attachment(engine, rtt_camera_handle, .FINAL_IMAGE)
    world.stage_material_data(&engine.world.staging, rtt_material_handle)
  }
}
