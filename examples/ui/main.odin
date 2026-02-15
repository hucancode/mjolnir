package main

import "../../mjolnir"
import cont "../../mjolnir/containers"
import "../../mjolnir/gpu"
import "../../mjolnir/render/ui"
import "../../mjolnir/world"
import "core:log"
import "core:math"

g_button: ui.Quad2DHandle
g_label: ui.Text2DHandle
g_star: ui.Mesh2DHandle
g_image_quad: ui.Quad2DHandle

// Helper function to create a 5-pointed star shape
create_star_mesh :: proc(
  center: [2]f32,
  outer_radius: f32,
  inner_radius: f32,
  color: [4]u8,
) -> (
  vertices: []ui.Vertex2D,
  indices: []u32,
) {
  // Create vertices: center + 5 outer points + 5 inner points
  vertices = make([]ui.Vertex2D, 11)
  indices = make([]u32, 30) // 10 triangles * 3 indices each

  // Center vertex
  vertices[0] = ui.Vertex2D {
    pos   = center,
    uv    = {0.5, 0.5},
    color = color,
  }

  // Generate star points
  for i in 0 ..< 5 {
    angle := f32(i) * (2.0 * math.PI / 5.0) - math.PI / 2.0

    // Outer point
    outer_idx := 1 + i * 2
    vertices[outer_idx] = ui.Vertex2D {
      pos   = {
        center.x + math.cos(angle) * outer_radius,
        center.y + math.sin(angle) * outer_radius,
      },
      uv    = {0.5 + math.cos(angle) * 0.5, 0.5 + math.sin(angle) * 0.5},
      color = color,
    }

    // Inner point (between outer points)
    inner_angle := angle + (math.PI / 5.0)
    inner_idx := 2 + i * 2
    vertices[inner_idx] = ui.Vertex2D {
      pos   = {
        center.x + math.cos(inner_angle) * inner_radius,
        center.y + math.sin(inner_angle) * inner_radius,
      },
      uv    = {
        0.5 + math.cos(inner_angle) * 0.3,
        0.5 + math.sin(inner_angle) * 0.3,
      },
      color = color,
    }
  }

  // Create triangles
  for i in 0 ..< 5 {
    outer_idx := u32(1 + i * 2)
    inner_idx := u32(2 + i * 2)
    next_outer_idx := u32(1 + ((i + 1) % 5) * 2)

    // Triangle from center to outer to inner
    indices[i * 6 + 0] = 0
    indices[i * 6 + 1] = outer_idx
    indices[i * 6 + 2] = inner_idx

    // Triangle from center to inner to next outer
    indices[i * 6 + 3] = 0
    indices[i * 6 + 4] = inner_idx
    indices[i * 6 + 5] = next_outer_idx
  }

  return vertices, indices
}

main :: proc() {
  context.logger = log.create_console_logger()
  engine := new(mjolnir.Engine)
  engine.setup_proc = proc(engine: ^mjolnir.Engine) {
    bg_quad, _ := ui.create_quad2d(
      &engine.render.ui_system,
      position = {50, 50},
      size = {700, 200},
      color = {40, 40, 60, 200},
      z_order = -1,
    )
    log.infof("Background quad created: handle=%v, ok=%v", bg_quad)

    // Create a star mesh using Mesh2D API
    star_vertices, star_indices := create_star_mesh(
      center = {500, 125},
      outer_radius = 70,
      inner_radius = 30,
      color = {255, 215, 0, 255}, // Gold color
    )
    defer delete(star_vertices)
    defer delete(star_indices)

    g_star, star_ok := ui.create_mesh2d(
      &engine.render.ui_system,
      position = {0, 0},
      vertices = star_vertices,
      indices = star_indices,
      z_order = 1,
    )
    log.infof("Star mesh created: handle=%v, ok=%v", g_star, star_ok)

    // Load image texture for display
    star_texture, texture_ok := gpu.create_texture_2d_from_path(
      &engine.gctx,
      &engine.render.texture_manager,
      "assets/gold-star.png",
    )
    log.infof(
      "Star texture loaded: handle=%v, ok=%v",
      star_texture,
      texture_ok,
    )

    // Create a textured quad to display the image
    if texture_ok == .SUCCESS {
      g_image_quad, image_quad_ok := ui.create_quad2d(
        &engine.render.ui_system,
        position = {350, 300},
        size = {128, 128},
        texture = star_texture,
        z_order = 1,
      )
      log.infof(
        "Image quad created: handle=%v, ok=%v",
        g_image_quad,
        image_quad_ok,
      )
    }

    // Create a simple colored quad as a button
    g_button, button_ok := ui.create_quad2d(
      &engine.render.ui_system,
      position = {100, 100},
      size = {200, 50},
      color = {255, 100, 100, 255}, // Red
      z_order = 0,
    )
    log.infof("Button quad created: handle=%v, ok=%v", g_button, button_ok)
    // Add "Click me!" label on the button, centered within the button bounds
    button_label, button_label_ok := ui.create_text2d(
      &engine.render.ui_system,
      &engine.render.ui,
      position = {100, 100}, // Same as button position
      text = "Click me!",
      font_size = 20,
      color = {255, 255, 255, 255},
      z_order = 2,
      bounds = {200, 50}, // Same as button size
      h_align = .Center,
      v_align = .Middle,
    )
    log.infof(
      "Button label created: handle=%v, ok=%v",
      button_label,
      button_label_ok,
    )

    // Add event handlers to the button
    if button := ui.get_quad2d(&engine.render.ui_system, g_button);
       button != nil {
      handlers := ui.EventHandlers {
        on_mouse_down = proc(event: ui.MouseEvent) {
          log.info("Button clicked!")
          engine := cast(^mjolnir.Engine)event.user_data
          if engine == nil do return
          if quad := ui.get_quad2d(
            &engine.render.ui_system,
            ui.Quad2DHandle(event.widget),
          ); quad != nil {
            quad.color = {100, 255, 100, 255}
          }
        },
        on_mouse_up = proc(event: ui.MouseEvent) {
          log.info("Button released!")
          engine := cast(^mjolnir.Engine)event.user_data
          if engine == nil do return
          if quad := ui.get_quad2d(
            &engine.render.ui_system,
            ui.Quad2DHandle(event.widget),
          ); quad != nil {
            quad.color = {255, 150, 100, 255}
          }
        },
        on_hover_in = proc(event: ui.MouseEvent) {
          log.info("Button hovered")
          engine := cast(^mjolnir.Engine)event.user_data
          if engine == nil do return
          if quad := ui.get_quad2d(
            &engine.render.ui_system,
            ui.Quad2DHandle(event.widget),
          ); quad != nil {
            quad.color = {255, 150, 100, 255}
          }
        },
        on_hover_out = proc(event: ui.MouseEvent) {
          log.info("Button unhovered")
          engine := cast(^mjolnir.Engine)event.user_data
          if engine == nil do return
          if quad := ui.get_quad2d(
            &engine.render.ui_system,
            ui.Quad2DHandle(event.widget),
          ); quad != nil {
            quad.color = {255, 100, 100, 255}
          }
        },
      }
      widget := cast(^ui.Widget)button
      ui.set_event_handler(widget, handlers)
      ui.set_user_data(widget, engine)
    }
    g_label, label_ok := ui.create_text2d(
      &engine.render.ui_system,
      &engine.render.ui,
      position = {100, 180},
      text = "The star is created using Mesh2D API!",
      font_size = 20,
      color = {255, 255, 255, 255},
      z_order = 1,
    )
    log.infof("Text label created: handle=%v, ok=%v", g_label, label_ok)

    // Add label for the textured quad
    image_label, image_label_ok := ui.create_text2d(
      &engine.render.ui_system,
      &engine.render.ui,
      position = {300, 440},
      text = "Image display using Quad2D with texture",
      font_size = 20,
      color = {255, 255, 255, 255},
      z_order = 1,
    )
    log.infof(
      "Image label created: handle=%v, ok=%v",
      image_label,
      image_label_ok,
    )
    mjolnir.spawn_primitive_mesh(engine, .CUBE, .BLUE)
    world.main_camera_look_at(
      &engine.world,
      engine.world.main_camera,
      {3, 2, 3},
      {0, 0, 0},
    )
  }
  mjolnir.run(engine, 800, 700, "UI")
}
