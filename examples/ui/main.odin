package main

import "../../mjolnir"
import "../../mjolnir/input"
import "../../mjolnir/platform"
import "../../mjolnir/render"
import "../../mjolnir/world"
import "core:log"
import "core:math"
import "core:os"

App :: struct {
  window:   platform.Platform,
  scene:    world.World,
  renderer: render.Manager,
  camera:   render.CameraController,
  input:    input.State,
  gui:      render.System,
}

button: render.Quad2DHandle
label: render.Text2DHandle
star: render.Mesh2DHandle
image_quad: render.Quad2DHandle

create_star_mesh :: proc(center: [2]f32, outer_radius, inner_radius: f32, color: [4]u8) -> (vertices: []render.Vertex2D, indices: []u32) {
  vertices = make([]render.Vertex2D, 11)
  indices = make([]u32, 30)
  vertices[0] = render.Vertex2D{pos = center, uv = {0.5, 0.5}, color = color}
  for i in 0 ..< 5 {
    angle := f32(i) * (2.0 * math.PI / 5.0) - math.PI / 2.0
    outer_idx := 1 + i * 2
    vertices[outer_idx] = render.Vertex2D{
      pos = {center.x + math.cos(angle) * outer_radius, center.y + math.sin(angle) * outer_radius},
      uv = {0.5 + math.cos(angle) * 0.5, 0.5 + math.sin(angle) * 0.5}, color = color,
    }
    inner_angle := angle + (math.PI / 5.0)
    inner_idx := 2 + i * 2
    vertices[inner_idx] = render.Vertex2D{
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
  context.logger = log.create_console_logger()
  app := new(App)
  defer free(app)
  w := &app.window
  if !platform.init(w, 800, 700, "UI") do return
  defer platform.shutdown(w)
  if !render.init(&app.renderer, "UI", platform.vulkan_instance_extensions(), platform.vulkan_get_instance_proc_addr(), platform.create_surface, w, platform.framebuffer_size(w), platform.dpi_scale(w)) do return
  defer render.shutdown(&app.renderer)
  if !world.init(&app.scene) do return
  defer world.shutdown(&app.scene)
  render.load_environment_map(&app.renderer, "assets/Cannon_Exterior.hdr")
  app.camera = render.orbit_controller()
  font, err := os.read_entire_file("assets/Outfit-Regular.ttf", context.allocator)
  if err != nil do return
  defer delete(font)
  if !render.ui_init(&app.gui, font) do return
  defer render.ui_shutdown(&app.gui)

  bg_quad, _ := render.create_quad2d(&app.gui, position = {50, 50}, size = {700, 200}, color = {40, 40, 60, 200}, z_order = -1)
  log.infof("Background quad created: handle=%v", bg_quad)

  star_vertices, star_indices := create_star_mesh(center = {500, 125}, outer_radius = 70, inner_radius = 30, color = {255, 215, 0, 255})
  defer delete(star_vertices)
  defer delete(star_indices)

  star, star_ok := render.create_mesh2d(&app.gui, position = {0, 0}, vertices = star_vertices, indices = star_indices, z_order = 1)
  log.infof("Star mesh created: handle=%v, ok=%v", star, star_ok)

  star_texture, texture_ret := render.create_texture_from_path(&app.renderer, "assets/gold-star.png")
  log.infof("Star texture loaded: handle=%v, ret=%v", star_texture, texture_ret)

  if texture_ret == .SUCCESS {
    image_quad, image_quad_ok := render.create_quad2d(&app.gui, position = {350, 300}, size = {128, 128}, texture = star_texture.index, z_order = 1)
    log.infof("Image quad created: handle=%v, ok=%v", image_quad, image_quad_ok)
  }

  button, button_ok := render.create_quad2d(&app.gui, position = {100, 100}, size = {200, 50}, color = {255, 100, 100, 255}, z_order = 0)
  log.infof("Button quad created: handle=%v, ok=%v", button, button_ok)

  button_label, button_label_ok := render.create_text2d(&app.gui, position = {100, 100}, text = "Click me!", font_size = 20, color = {255, 255, 255, 255}, z_order = 2, bounds = {200, 50}, h_align = .Center, v_align = .Middle)
  log.infof("Button label created: handle=%v, ok=%v", button_label, button_label_ok)

  if btn := render.get_quad2d(&app.gui, button); btn != nil {
    handlers := render.EventHandlers{
      on_mouse_down = proc(event: render.MouseEvent) {
        log.info("Button clicked!")
        app := cast(^App)event.user_data
        if app == nil do return
        if q := render.get_quad2d(&app.gui, render.Quad2DHandle(event.widget)); q != nil do q.color = {100, 255, 100, 255}
      },
      on_mouse_up = proc(event: render.MouseEvent) {
        log.info("Button released!")
        app := cast(^App)event.user_data
        if app == nil do return
        if q := render.get_quad2d(&app.gui, render.Quad2DHandle(event.widget)); q != nil do q.color = {255, 150, 100, 255}
      },
      on_hover_in = proc(event: render.MouseEvent) {
        log.info("Button hovered")
        app := cast(^App)event.user_data
        if app == nil do return
        if q := render.get_quad2d(&app.gui, render.Quad2DHandle(event.widget)); q != nil do q.color = {255, 150, 100, 255}
      },
      on_hover_out = proc(event: render.MouseEvent) {
        log.info("Button unhovered")
        app := cast(^App)event.user_data
        if app == nil do return
        if q := render.get_quad2d(&app.gui, render.Quad2DHandle(event.widget)); q != nil do q.color = {255, 100, 100, 255}
      },
    }
    btn.event_handlers = handlers
    btn.user_data = app
  }
  label, label_ok := render.create_text2d(&app.gui, position = {100, 180}, text = "The star is created using Mesh2D API!", font_size = 20, color = {255, 255, 255, 255}, z_order = 1)
  log.infof("Text label created: handle=%v, ok=%v", label, label_ok)

  image_label, image_label_ok := render.create_text2d(&app.gui, position = {300, 440}, text = "Image display using Quad2D with texture", font_size = 20, color = {255, 255, 255, 255}, z_order = 1)
  log.infof("Image label created: handle=%v, ok=%v", image_label, image_label_ok)

  cube := world.spawn(&app.scene)
  render.attach(&app.renderer, cube.index, render.primitive(&app.renderer, .CUBE, .BLUE))
  render.main_camera_look_at(&app.renderer, {3, 2, 3}, {0, 0, 0})

  mjolnir.run(mjolnir.Loop(App){app = app, should_close = should_close, update = update, frame = frame})
}

should_close :: proc(app: ^App) -> bool {
  return platform.should_close(&app.window)
}

update :: proc(app: ^App, dt: f32) {
  platform.read_input(&app.window, &app.input)
  render.process_input(&app.gui, &app.input)
  render.camera_controller_update(&app.camera, &app.renderer, &app.input, dt)
  world.update(&app.scene)
  for i in world.removed_nodes(&app.scene) do render.stage_slot_removal(&app.renderer, i)
  for n in world.changed_nodes(&app.scene) do render.stage_transform(&app.renderer, n.index, n.world_matrix, n.visible)
  render.update(&app.renderer, dt)
}

frame :: proc(app: ^App) -> bool {
  platform.poll_events(&app.window)
  render.stage_ui(&app.renderer, render.draw_list(&app.gui))
  return render.frame(&app.renderer, platform.framebuffer_size(&app.window), platform.dpi_scale(&app.window))
}
