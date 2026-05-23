package main

import "../../mjolnir"
import "core:math"
import "core:math/linalg"

rtt_camera_handle: mjolnir.CameraHandle
rtt_material_handle: mjolnir.MaterialHandle
spinner_handle: mjolnir.NodeHandle

main :: proc() {
  mjolnir.run_app({
    title       = "Render To Texture",
    setup       = setup,
    update      = update,
    post_render = on_post_render,
  })
}

setup :: proc(engine: ^mjolnir.Engine) {
  mjolnir.main_camera_look_at(engine, {5, 3, 6}, {0, 1, 0})

  ground := mjolnir.spawn_primitive_mesh(engine, .QUAD_XZ, .GRAY)
  mjolnir.scale(engine, ground, 6.0)

  mjolnir.spawn_primitive_mesh(engine, .CUBE,   .RED,   position = {-1.5, 0.5, 0})
  mjolnir.spawn_primitive_mesh(engine, .SPHERE, .GREEN, position = {0, 0.6, 1.0}, scale_factor = 0.6)
  mjolnir.spawn_primitive_mesh(engine, .CONE,   .BLUE,  position = {1.5, 0.5, -0.5})
  spinner_handle = mjolnir.spawn_primitive_mesh(engine, .CUBE, .YELLOW, position = {0, 1.8, 0}, scale_factor = 0.4)

  mjolnir.spawn_light_point(engine, {0, 3, 1.5}, {1.0, 0.6, 0.3, 1.0}, 12.0, false)

  rtt_camera_handle = mjolnir.create_camera(engine, 512, 512, {.GEOMETRY, .LIGHTING, .TRANSPARENCY}, {0, 8, 0.01}, {0, 0, 0}, math.PI * 0.5, 0.1, 100.0)
  rtt_material_handle = mjolnir.create_material(engine, {.ALBEDO_TEXTURE})

  display_mesh := mjolnir.builtin_mesh(engine, .QUAD_XY)
  display_handle := mjolnir.spawn(engine, {0, 2.5, -3.5}, mjolnir.MeshAttachment{handle = display_mesh, material = rtt_material_handle, cast_shadow = false})
  mjolnir.scale(engine, display_handle, 3.0)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  mjolnir.rotate(engine, spinner_handle, mjolnir.time_since_start(engine), linalg.VECTOR3F32_Y_AXIS)
}

on_post_render :: proc(engine: ^mjolnir.Engine) {
  if mat, ok := mjolnir.material(engine, rtt_material_handle); ok {
    mat.albedo = mjolnir.get_camera_attachment(engine, rtt_camera_handle, .FINAL_IMAGE, engine.frame_index)
    mjolnir.stage_material_data(engine, rtt_material_handle)
  }
}
