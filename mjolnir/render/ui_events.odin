package render

import cont "../containers"
import "../input"

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
  button:    input.MouseButton, // CLICK_DOWN / CLICK_UP only
  widget:    UIWidgetHandle, // target; stays the same while bubbling
  user_data: rawptr, // of the widget whose handler runs
}

KeyEvent :: struct {
  type:      KeyEventType,
  key:       input.Key,
  repeat:    bool, // KEY_DOWN from OS auto-repeat
  widget:    UIWidgetHandle,
  user_data: rawptr,
}

TextEvent :: struct {
  text:      string, // UTF-8, valid only during the handler
  widget:    UIWidgetHandle,
  user_data: rawptr,
}

MouseEventProc :: #type proc(event: MouseEvent)
KeyEventProc :: #type proc(event: KeyEvent)
TextEventProc :: #type proc(event: TextEvent)

EventHandlers :: struct {
  on_mouse_down: MouseEventProc,
  on_mouse_up:   MouseEventProc,
  on_move:       MouseEventProc,
  on_hover_in:   MouseEventProc,
  on_hover_out:  MouseEventProc,
  on_key_down:   KeyEventProc,
  on_key_up:     KeyEventProc,
  on_text:       TextEventProc,
}

@(private)
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
      p0 := w.world_position + glyph.p0
      p1 := w.world_position + glyph.p1
      min_x = min(min_x, p0.x)
      min_y = min(min_y, p0.y)
      max_x = max(max_x, p1.x)
      max_y = max(max_y, p1.y)
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

// Topmost visible widget containing `point`. With `interactive_only`, only
// widgets that handle mouse events (themselves or via an ancestor) count.
@(private)
pick_widget :: proc(
  sys: ^System,
  point: [2]f32,
  interactive_only := false,
) -> Maybe(UIWidgetHandle) {
  best_widget: Maybe(UIWidgetHandle) = nil
  best_z: i32 = min(i32)
  it := cont.iterator(&sys.widget_pool)
  for widget, handle in cont.next(&it, UIWidgetHandle) {
    base := get_widget_base(widget)
    if !base.visible || base.z_order <= best_z && best_widget != nil do continue
    if !point_in_widget(widget, point) do continue
    if interactive_only && !handles_mouse(sys, handle) do continue
    best_z = base.z_order
    best_widget = handle
  }
  return best_widget
}

@(private)
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

@(private)
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

@(private)
dispatch_text_event :: proc(sys: ^System, widget_handle: UIWidgetHandle, event: TextEvent) {
  widget := get_widget(sys, widget_handle)
  if widget == nil do return
  base := get_widget_base(widget)
  event := event
  event.user_data = base.user_data
  if base.event_handlers.on_text != nil do base.event_handlers.on_text(event)
  if parent, has_parent := base.parent.?; has_parent {
    dispatch_text_event(sys, parent, event)
  }
}

// True when the mouse belongs to the UI: an interactive widget is hovered or
// holds a press.
@(private)
wants_mouse :: proc(sys: ^System) -> bool {
  return sys.hovered != nil || sys.captured != nil
}

// True when the focused widget (or an ancestor) handles key or text events.
@(private)
wants_keyboard :: proc(sys: ^System) -> bool {
  h, ok := sys.focused.?
  for ok {
    widget := get_widget(sys, h)
    if widget == nil do return false
    base := get_widget_base(widget)
    e := base.event_handlers
    if e.on_key_down != nil || e.on_key_up != nil || e.on_text != nil do return true
    h, ok = base.parent.?
  }
  return false
}

// Run one tick of input through the widget tree, then capture the mouse /
// keyboard the UI owns (see input.State). Skipped while another consumer
// (the debug UI) holds the mouse.
process_input :: proc(sys: ^System, s: ^input.State) {
  if s.mouse_captured do return
  dispatch_input(sys, s)
  if wants_mouse(sys) do s.mouse_captured = true
  if wants_keyboard(sys) do s.keyboard_captured = true
}

// Run one tick of input through the widget tree. Hit testing considers only
// interactive widgets (see pick_widget). Dispatches HOVER_IN / HOVER_OUT when
// the hovered widget changes, MOVE to the captured or hovered widget,
// CLICK_DOWN to the hovered widget (capturing it and taking focus; a press
// over nothing clears focus), CLICK_UP to the captured widget, and key and
// text events to the focused widget. Every event bubbles to the parents.
@(private = "file")
dispatch_input :: proc(sys: ^System, s: ^input.State) {
  pos := s.cursor
  current := pick_widget(sys, pos, interactive_only = true)
  if current != sys.hovered {
    if h, ok := sys.hovered.?; ok {
      dispatch_mouse_event(sys, h, {type = .HOVER_OUT, position = pos, widget = h})
    }
    if h, ok := current.?; ok {
      dispatch_mouse_event(sys, h, {type = .HOVER_IN, position = pos, widget = h})
    }
    sys.hovered = current
  }
  if s.mouse_delta != {} {
    target := sys.captured if sys.captured != nil else current
    if h, ok := target.?; ok {
      dispatch_mouse_event(sys, h, {type = .MOVE, position = pos, widget = h})
    }
  }
  for b in input.MouseButton {
    if input.mouse_pressed(s, b) {
      sys.focused = current
      if sys.captured == nil do sys.captured = current
      if h, ok := current.?; ok {
        dispatch_mouse_event(sys, h, {type = .CLICK_DOWN, position = pos, button = b, widget = h})
      }
    }
    if input.mouse_released(s, b) {
      target := sys.captured if sys.captured != nil else current
      if h, ok := target.?; ok {
        dispatch_mouse_event(sys, h, {type = .CLICK_UP, position = pos, button = b, widget = h})
      }
    }
  }
  if s.buttons == {} do sys.captured = nil
  h, has_focus := sys.focused.?
  if !has_focus do return
  if get_widget(sys, h) == nil {
    sys.focused = nil
    return
  }
  it := 0
  for key, pressed in input.next_key_edge(s, &it) {
    dispatch_key_event(sys, h, {type = .KEY_DOWN if pressed else .KEY_UP, key = key, widget = h})
  }
  for key in input.Key {
    if !input.key_repeated(s, key) do continue
    dispatch_key_event(sys, h, {type = .KEY_DOWN, key = key, repeat = true, widget = h})
  }
  if t := input.text(s); len(t) > 0 {
    dispatch_text_event(sys, h, {text = t, widget = h})
  }
}

@(private)
handles_mouse :: proc(sys: ^System, handle: UIWidgetHandle) -> bool {
  h, ok := handle, true
  for ok {
    widget := get_widget(sys, h)
    if widget == nil do return false
    base := get_widget_base(widget)
    e := base.event_handlers
    if e.on_mouse_down != nil || e.on_mouse_up != nil || e.on_move != nil ||
       e.on_hover_in != nil || e.on_hover_out != nil {
      return true
    }
    h, ok = base.parent.?
  }
  return false
}
