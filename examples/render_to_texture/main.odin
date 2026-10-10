package main

import "../../mjolnir"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:math"
import "core:math/linalg"

rtt_camera_handle: render.CameraHandle
rtt_material_handle: render.MaterialHandle
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
  render.main_camera_look_at(&engine.render, {5, 3, 6}, {0, 1, 0})

  mjolnir.spawn_ground(engine, 6.0)

  mjolnir.spawn_primitive_mesh(engine, .CUBE,   .RED,   position = {-1.5, 0.5, 0})
  mjolnir.spawn_primitive_mesh(engine, .SPHERE, .GREEN, position = {0, 0.6, 1.0}, scale_factor = 0.6)
  mjolnir.spawn_primitive_mesh(engine, .CONE,   .BLUE,  position = {1.5, 0.5, -0.5})
  spinner_handle = mjolnir.spawn_primitive_mesh(engine, .CUBE, .YELLOW, position = {0, 1.8, 0}, scale_factor = 0.4)

  mjolnir.spawn(engine, {0, 3, 1.5}, render.point_light_attachment({1.0, 0.6, 0.3, 1.0}, 12.0, false))

  rtt_camera_handle = render.create_camera(&engine.render, 512, 512, {.GEOMETRY, .LIGHTING, .TRANSPARENCY}, {0, 8, 0.01}, {0, 0, 0}, math.PI * 0.5, 0.1, 100.0)
  rtt_material_handle = render.create_material(&engine.render, {.ALBEDO_TEXTURE})

  display_mesh := render.get_builtin_mesh(&engine.render, .QUAD_XY)
  display_handle := mjolnir.spawn(engine, {0, 2.5, -3.5}, render.MeshAttachment{handle = display_mesh, material = rtt_material_handle, cast_shadow = false})
  world.scale(&engine.world, display_handle, 3.0)
}

update :: proc(engine: ^mjolnir.Engine, dt: f32) {
  world.rotate(&engine.world, spinner_handle, mjolnir.time_since_start(engine), linalg.VECTOR3F32_Y_AXIS)
  world.update(&engine.world)
  for i in world.removed_nodes(&engine.world) do render.stage_slot_removal(&engine.render, i)
  for n in world.changed_nodes(&engine.world) do render.stage_transform(&engine.render, n.index, n.world_matrix, n.visible)
}

on_post_render :: proc(engine: ^mjolnir.Engine) {
  if mat, ok := render.material(&engine.render, rtt_material_handle); ok {
    mat.albedo = render.camera_attachment(&engine.render, rtt_camera_handle, .FINAL_IMAGE)
    render.mark_material_dirty(&engine.render, rtt_material_handle)
  }
}
