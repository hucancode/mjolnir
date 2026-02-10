package ui

import cont "../../containers"
import "../../gpu"
import d "../../data"
import "core:log"
import vk "vendor:vulkan"

System :: struct {
  widget_pool:     cont.Pool(Widget),
  default_texture: d.Image2DHandle,
}

init_ui_system :: proc(self: ^System, max_widgets: u32 = 4096) {
  cont.init(&self.widget_pool, max_widgets)
  log.info("UI system initialized")
}

shutdown_ui_system :: proc(self: ^System) {
  // Clean up all active widgets
  cont.destroy(self.widget_pool, cleanup_widget)
  log.info("UI system shutdown")
}

cleanup_widget :: proc(widget: ^Widget) {
  switch &w in widget {
  case Mesh2D:
    delete(w.vertices)
    delete(w.indices)
  case Quad2D:
  // No dynamic allocations
  case Text2D:
    delete(w.text)
    delete(w.glyphs)
  case Box:
    // Note: children are already destroyed by pool iteration
    delete(w.children)
  }
}

UIWidgetHandle :: distinct cont.Handle
Mesh2DHandle :: distinct UIWidgetHandle
Quad2DHandle :: distinct UIWidgetHandle
Text2DHandle :: distinct UIWidgetHandle
BoxHandle :: distinct UIWidgetHandle

Vertex2D :: struct {
  pos:        [2]f32,
  uv:         [2]f32,
  color:      [4]u8,
  texture_id: u32,
}

WidgetType :: enum {
  Mesh2D,
  Quad2D,
  Text2D,
  Box,
}

get_widget :: proc(sys: ^System, handle: UIWidgetHandle) -> ^Widget {
  widget, ok := cont.get(sys.widget_pool, handle)
  if !ok do return nil
  return widget
}

get_mesh2d :: proc(sys: ^System, handle: Mesh2DHandle) -> ^Mesh2D {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  #partial switch &w in widget {
  case Mesh2D:
    return &w
  }
  return nil
}

get_quad2d :: proc(sys: ^System, handle: Quad2DHandle) -> ^Quad2D {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  #partial switch &w in widget {
  case Quad2D:
    return &w
  }
  return nil
}

get_text2d :: proc(sys: ^System, handle: Text2DHandle) -> ^Text2D {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  #partial switch &w in widget {
  case Text2D:
    return &w
  }
  return nil
}

get_box :: proc(sys: ^System, handle: BoxHandle) -> ^Box {
  widget := get_widget(sys, UIWidgetHandle(handle))
  if widget == nil do return nil
  #partial switch &w in widget {
  case Box:
    return &w
  }
  return nil
}

set_position :: proc(widget: ^Widget, position: [2]f32) {
  switch &w in widget {
  case Mesh2D:
    w.position = position
  case Quad2D:
    w.position = position
  case Text2D:
    w.position = position
  case Box:
    w.position = position
  }
}

set_z_order :: proc(widget: ^Widget, z: i32) {
  switch &w in widget {
  case Mesh2D:
    w.z_order = z
  case Quad2D:
    w.z_order = z
  case Text2D:
    w.z_order = z
  case Box:
    w.z_order = z
  }
}

set_visible :: proc(widget: ^Widget, visible: bool) {
  switch &w in widget {
  case Mesh2D:
    w.visible = visible
  case Quad2D:
    w.visible = visible
  case Text2D:
    w.visible = visible
  case Box:
    w.visible = visible
  }
}

set_event_handler :: proc(widget: ^Widget, handlers: EventHandlers) {
  switch &w in widget {
  case Mesh2D:
    w.event_handlers = handlers
  case Quad2D:
    w.event_handlers = handlers
  case Text2D:
    w.event_handlers = handlers
  case Box:
    w.event_handlers = handlers
  }
}

set_user_data :: proc(widget: ^Widget, data: rawptr) {
  switch &w in widget {
  case Mesh2D:
    w.user_data = data
  case Quad2D:
    w.user_data = data
  case Text2D:
    w.user_data = data
  case Box:
    w.user_data = data
  }
}

destroy_widget :: proc(sys: ^System, handle: UIWidgetHandle) {
  widget := get_widget(sys, handle)
  if widget == nil do return

  switch &w in widget {
  case Mesh2D:
    delete(w.vertices)
    delete(w.indices)
  case Quad2D:
  // No dynamic allocations
  case Text2D:
    delete(w.text)
    delete(w.glyphs)
  case Box:
    // Destroy children recursively
    for child in w.children {
      destroy_widget(sys, child)
    }
    delete(w.children)
  }

  cont.free(&sys.widget_pool, handle)
}
