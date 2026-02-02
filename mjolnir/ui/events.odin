package ui

import cont "../containers"
import res "../resources"
import "core:log"
import "core:math/linalg"

MouseEventType :: enum {
  CLICK_DOWN,
  CLICK_UP,
  MOVE,
  HOVER_IN,
  HOVER_OUT,
}

KeyEventType :: enum {
  KEY_DOWN,
  KEY_UP,
}

MouseEvent :: struct {
  type:      MouseEventType,
  position:  [2]f32,
  button:    i32,
  widget:    UIWidgetHandle,
  user_data: rawptr,
}

KeyEvent :: struct {
  type:      KeyEventType,
  key:       i32,
  widget:    UIWidgetHandle,
  user_data: rawptr,
}

MouseEventProc :: #type proc(event: MouseEvent)
KeyEventProc :: #type proc(event: KeyEvent)

EventHandlers :: struct {
  on_mouse_down: MouseEventProc,
  on_mouse_up:   MouseEventProc,
  on_move:       MouseEventProc,
  on_hover_in:   MouseEventProc,
  on_hover_out:  MouseEventProc,
  on_key_down:   KeyEventProc,
  on_key_up:     KeyEventProc,
}

point_in_widget :: proc(widget: ^Widget, point: [2]f32) -> bool {
  switch w in widget {
  case Quad2D:
    return(
      point.x >= w.world_position.x &&
      point.x <= w.world_position.x + w.size.x &&
      point.y >= w.world_position.y &&
      point.y <= w.world_position.y + w.size.y \
    )
  case Box:
    return(
      point.x >= w.world_position.x &&
      point.x <= w.world_position.x + w.size.x &&
      point.y >= w.world_position.y &&
      point.y <= w.world_position.y + w.size.y \
    )
  case Text2D:
    if len(w.glyphs) == 0 do return false
    min_x := w.world_position.x
    min_y := w.world_position.y
    max_x := min_x
    max_y := min_y
    for glyph in w.glyphs {
      x0 := w.world_position.x + glyph.x0
      y0 := w.world_position.y + glyph.y0
      x1 := w.world_position.x + glyph.x1
      y1 := w.world_position.y + glyph.y1
      min_x = min(min_x, x0)
      min_y = min(min_y, y0)
      max_x = max(max_x, x1)
      max_y = max(max_y, y1)
    }
    return(
      point.x >= min_x &&
      point.x <= max_x &&
      point.y >= min_y &&
      point.y <= max_y \
    )
  case Mesh2D:
    if len(w.vertices) == 0 do return false
    min_x := w.world_position.x + w.vertices[0].pos.x
    min_y := w.world_position.y + w.vertices[0].pos.y
    max_x := min_x
    max_y := min_y
    for v in w.vertices {
      vx := w.world_position.x + v.pos.x
      vy := w.world_position.y + v.pos.y
      min_x = min(min_x, vx)
      min_y = min(min_y, vy)
      max_x = max(max_x, vx)
      max_y = max(max_y, vy)
    }
    return(
      point.x >= min_x &&
      point.x <= max_x &&
      point.y >= min_y &&
      point.y <= max_y \
    )
  }
  return false
}

pick_widget :: proc(sys: ^System, point: [2]f32) -> Maybe(UIWidgetHandle) {
  best_widget: Maybe(UIWidgetHandle) = nil
  best_z: i32 = min(i32)

  for &entry, i in sys.widget_pool.entries {
    if !entry.active do continue

    widget := &entry.item
    if widget == nil do continue
    if !get_widget_base(widget).visible do continue

    if point_in_widget(widget, point) {
      z := get_widget_base(widget).z_order
      if z > best_z {
        best_z = z
        // Construct handle from entry
        raw_handle: cont.Handle
        raw_handle.index = u32(i)
        raw_handle.generation = entry.generation
        best_widget = transmute(UIWidgetHandle)raw_handle
      }
    }
  }

  return best_widget
}

dispatch_mouse_event :: proc(
  sys: ^System,
  widget_handle: UIWidgetHandle,
  event: MouseEvent,
  bubble: bool = true,
) {
  widget := get_widget(sys, widget_handle)
  if widget == nil do return

  base := get_widget_base(widget)
  if base == nil do return

  // Set user_data from widget
  event := event
  event.user_data = base.user_data

  // Call handler based on event type
  switch event.type {
  case .CLICK_DOWN:
    if base.event_handlers.on_mouse_down != nil {
      base.event_handlers.on_mouse_down(event)
    }
  case .CLICK_UP:
    if base.event_handlers.on_mouse_up != nil {
      base.event_handlers.on_mouse_up(event)
    }
  case .MOVE:
    if base.event_handlers.on_move != nil {
      base.event_handlers.on_move(event)
    }
  case .HOVER_IN:
    if base.event_handlers.on_hover_in != nil {
      base.event_handlers.on_hover_in(event)
    }
  case .HOVER_OUT:
    if base.event_handlers.on_hover_out != nil {
      base.event_handlers.on_hover_out(event)
    }
  }

  // Bubble UP to parent
  if bubble {
    if parent_handle, has_parent := base.parent.?; has_parent {
      dispatch_mouse_event(sys, parent_handle, event, true)
    }
  }
}

dispatch_key_event :: proc(
  sys: ^System,
  widget_handle: UIWidgetHandle,
  event: KeyEvent,
  bubble: bool = true,
) {
  widget := get_widget(sys, widget_handle)
  if widget == nil do return

  base := get_widget_base(widget)
  if base == nil do return

  // Set user_data from widget
  event := event
  event.user_data = base.user_data

  // Call handler based on event type
  switch event.type {
  case .KEY_DOWN:
    if base.event_handlers.on_key_down != nil {
      base.event_handlers.on_key_down(event)
    }
  case .KEY_UP:
    if base.event_handlers.on_key_up != nil {
      base.event_handlers.on_key_up(event)
    }
  }

  // Bubble UP to parent
  if bubble {
    if parent_handle, has_parent := base.parent.?; has_parent {
      dispatch_key_event(sys, parent_handle, event, true)
    }
  }
}
