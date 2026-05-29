package main

import "../../mjolnir"
import "../../mjolnir/gpu"
import cmd "../../mjolnir/gpu/ui"
import "../../mjolnir/ui"
import "../../mjolnir/world"
import "core:log"
import "core:math"

button: ui.Quad2DHandle
label: ui.Text2DHandle
star: ui.Mesh2DHandle
image_quad: ui.Quad2DHandle

create_star_mesh :: proc(center: [2]f32, outer_radius, inner_radius: f32, color: [4]u8) -> (vertices: []cmd.Vertex2D, indices: []u32) {
  vertices = make([]cmd.Vertex2D, 11)
  indices = make([]u32, 30)
  vertices[0] = cmd.Vertex2D{pos = center, uv = {0.5, 0.5}, color = color}
  for i in 0 ..< 5 {
    angle := f32(i) * (2.0 * math.PI / 5.0) - math.PI / 2.0
    outer_idx := 1 + i * 2
    vertices[outer_idx] = cmd.Vertex2D{
      pos = {center.x + math.cos(angle) * outer_radius, center.y + math.sin(angle) * outer_radius},
      uv = {0.5 + math.cos(angle) * 0.5, 0.5 + math.sin(angle) * 0.5}, color = color,
    }
    inner_angle := angle + (math.PI / 5.0)
    inner_idx := 2 + i * 2
    vertices[inner_idx] = cmd.Vertex2D{
      pos = {center.x + math.cos(inner_angle) * inner_radius, center.y + math.sin(inner_angle) * inner_radius},
      uv = {0.5 + math.cos(inner_angle) * 0.3, 0.5 + math.sin(inner_angle) * 0.3}, color = color,
    }
  }
  for i in 0 ..< 5 {
    outer := u32(1 + i * 2); inner := u32(2 + i * 2); next_outer := u32(1 + ((i + 1) % 5) * 2)
    indices[i * 6 + 0] = 0; indices[i * 6 + 1] = outer; indices[i * 6 + 2] = inner
    indices[i * 6 + 3] = 0; indices[i * 6 + 4] = inner; indices[i * 6 + 5] = next_outer
  }
  return
}

main :: proc() {
  mjolnir.run_app({title = "UI", width = 800, height = 700, setup = setup})
}

setup :: proc(engine: ^mjolnir.Engine) {
  bg_quad, _ := ui.create_quad2d(&engine.ui, position = {50, 50}, size = {700, 200}, color = {40, 40, 60, 200}, z_order = -1)
  log.infof("Background quad created: handle=%v", bg_quad)

  star_vertices, star_indices := create_star_mesh(center = {500, 125}, outer_radius = 70, inner_radius = 30, color = {255, 215, 0, 255})
  defer delete(star_vertices)
  defer delete(star_indices)

  star, star_ok := ui.create_mesh2d(&engine.ui, position = {0, 0}, vertices = star_vertices, indices = star_indices, z_order = 1)
  log.infof("Star mesh created: handle=%v, ok=%v", star, star_ok)

  star_texture, texture_ret := gpu.create_texture_2d_from_path(&engine.gctx, &engine.render.texture_manager, "assets/gold-star.png")
  log.infof("Star texture loaded: handle=%v, ret=%v", star_texture, texture_ret)

  if texture_ret == .SUCCESS {
    image_quad, image_quad_ok := ui.create_quad2d(&engine.ui, position = {350, 300}, size = {128, 128}, texture = star_texture, z_order = 1)
    log.infof("Image quad created: handle=%v, ok=%v", image_quad, image_quad_ok)
  }

  button, button_ok := ui.create_quad2d(&engine.ui, position = {100, 100}, size = {200, 50}, color = {255, 100, 100, 255}, z_order = 0)
  log.infof("Button quad created: handle=%v, ok=%v", button, button_ok)

  button_label, button_label_ok := ui.create_text2d(&engine.ui, position = {100, 100}, text = "Click me!", font_size = 20, color = {255, 255, 255, 255}, z_order = 2, bounds = {200, 50}, h_align = .Center, v_align = .Middle)
  log.infof("Button label created: handle=%v, ok=%v", button_label, button_label_ok)

  if btn := ui.get_quad2d(&engine.ui, button); btn != nil {
    handlers := ui.EventHandlers{
      on_mouse_down = proc(event: ui.MouseEvent) {
        log.info("Button clicked!")
        engine := cast(^mjolnir.Engine)event.user_data
        if engine == nil do return
        if q := ui.get_quad2d(&engine.ui, ui.Quad2DHandle(event.widget)); q != nil do q.color = {100, 255, 100, 255}
      },
      on_mouse_up = proc(event: ui.MouseEvent) {
        log.info("Button released!")
        engine := cast(^mjolnir.Engine)event.user_data
        if engine == nil do return
        if q := ui.get_quad2d(&engine.ui, ui.Quad2DHandle(event.widget)); q != nil do q.color = {255, 150, 100, 255}
      },
      on_hover_in = proc(event: ui.MouseEvent) {
        log.info("Button hovered")
        engine := cast(^mjolnir.Engine)event.user_data
        if engine == nil do return
        if q := ui.get_quad2d(&engine.ui, ui.Quad2DHandle(event.widget)); q != nil do q.color = {255, 150, 100, 255}
      },
      on_hover_out = proc(event: ui.MouseEvent) {
        log.info("Button unhovered")
        engine := cast(^mjolnir.Engine)event.user_data
        if engine == nil do return
        if q := ui.get_quad2d(&engine.ui, ui.Quad2DHandle(event.widget)); q != nil do q.color = {255, 100, 100, 255}
      },
    }
    widget := cast(^ui.Widget)btn
    ui.set_event_handler(widget, handlers)
    ui.set_user_data(widget, engine)
  }
  label, label_ok := ui.create_text2d(&engine.ui, position = {100, 180}, text = "The star is created using Mesh2D API!", font_size = 20, color = {255, 255, 255, 255}, z_order = 1)
  log.infof("Text label created: handle=%v, ok=%v", label, label_ok)

  image_label, image_label_ok := ui.create_text2d(&engine.ui, position = {300, 440}, text = "Image display using Quad2D with texture", font_size = 20, color = {255, 255, 255, 255}, z_order = 1)
  log.infof("Image label created: handle=%v, ok=%v", image_label, image_label_ok)

  world.spawn_primitive_mesh(&engine.world, .CUBE, .BLUE)
  world.main_camera_look_at(&engine.world, {3, 2, 3}, {0, 0, 0})
}
